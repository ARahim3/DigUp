//! Showing a mail in classic Outlook, through its COM automation (late bound, as a script would): the store whose file
//! is the PST, the mail by its EntryID in that store, its window brought to the front. Outlook starts if it isn't
//! running, with its default profile. Nothing is changed in the profile: a PST that isn't open in Outlook is reported
//! (exit 5), not added.

use std::{path::Path, process::ExitCode};

#[cfg(not(windows))]
pub fn show(_file: &Path, _node: u32) -> ExitCode {
    eprintln!("opening a mail needs classic Outlook on Windows");
    ExitCode::from(4)
}

#[cfg(windows)]
pub fn show(file: &Path, node: u32) -> ExitCode {
    match windows_outlook::show(file, node) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            eprintln!("{}", failure.message);
            ExitCode::from(failure.code)
        }
    }
}

#[cfg(windows)]
mod windows_outlook {
    use std::{mem::ManuallyDrop, path::Path, thread::sleep, time::Duration};

    use windows::{
        core::{IUnknown, Interface, BSTR, GUID, HRESULT, PCWSTR, VARIANT},
        Win32::{
            System::Com::{
                CLSIDFromProgID, CoCreateInstance, CoInitializeEx, IDispatch, CLSCTX_LOCAL_SERVER,
                COINIT_APARTMENTTHREADED, DISPATCH_FLAGS, DISPATCH_METHOD, DISPATCH_PROPERTYGET, DISPPARAMS, EXCEPINFO,
            },
            UI::WindowsAndMessaging::{AllowSetForegroundWindow, ASFW_ANY},
        },
    };

    pub struct Failure {
        pub code: u8,
        pub message: String,
    }

    fn fail(code: u8, message: impl Into<String>) -> Failure {
        Failure { code, message: message.into() }
    }

    /// Outlook answers "busy" while it starts or shows a dialog: calls are tried again for a while.
    const RPC_E_CALL_REJECTED: HRESULT = HRESULT(0x8001_0001_u32 as i32);
    const RPC_E_SERVERCALL_RETRYLATER: HRESULT = HRESULT(0x8001_010A_u32 as i32);
    const TYPE_E_TYPEMISMATCH: HRESULT = HRESULT(0x8002_8CA0_u32 as i32);
    const LOCALE_USER_DEFAULT: u32 = 0x0400;
    /// PR_RECORD_KEY of a store: the PST's own id, which its mails' EntryIDs carry.
    const RECORD_KEY: &str = "http://schemas.microsoft.com/mapi/proptag/0x0FF90102";

    struct Object(IDispatch);

    impl Object {
        fn call(&self, name: &str, flags: DISPATCH_FLAGS, args: &[VARIANT]) -> windows::core::Result<VARIANT> {
            let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
            let names = [PCWSTR(wide.as_ptr())];
            let mut id = 0i32;
            // Arguments go in reverse order.
            let mut args: Vec<VARIANT> = args.iter().rev().cloned().collect();
            let params = DISPPARAMS {
                rgvarg: args.as_mut_ptr(),
                cArgs: args.len() as u32,
                ..Default::default()
            };
            let mut tries = 0;
            loop {
                let mut exception = EXCEPINFO::default();
                let result = unsafe {
                    self.0.GetIDsOfNames(&GUID::zeroed(), names.as_ptr(), 1, LOCALE_USER_DEFAULT, &mut id).and_then(
                        |()| {
                            let mut value = VARIANT::default();
                            self.0
                                .Invoke(id, &GUID::zeroed(), LOCALE_USER_DEFAULT, flags, &params, Some(&mut value),
                                        Some(&mut exception), None)
                                .map(|()| value)
                        },
                    )
                };
                // Outlook says what went wrong in the exception's description ("a dialog box is open"…).
                let description = ManuallyDrop::into_inner(exception.bstrDescription).to_string();
                drop(ManuallyDrop::into_inner(exception.bstrSource));
                drop(ManuallyDrop::into_inner(exception.bstrHelpFile));
                let result = result.map_err(|err| {
                    if description.is_empty() { err } else { windows::core::Error::new(err.code(), description) }
                });
                match result {
                    Err(err) if (err.code() == RPC_E_CALL_REJECTED || err.code() == RPC_E_SERVERCALL_RETRYLATER)
                        && tries < 60 => {
                        tries += 1;
                        sleep(Duration::from_millis(500));
                    }
                    other => return other,
                }
            }
        }

        fn get(&self, name: &str) -> windows::core::Result<VARIANT> {
            self.call(name, DISPATCH_PROPERTYGET, &[])
        }

        fn method(&self, name: &str, args: &[VARIANT]) -> windows::core::Result<VARIANT> {
            self.call(name, DISPATCH_METHOD, args)
        }

        /// The object a call returned. Outlook hands objects back as VT_DISPATCH, which windows-core's conversions
        /// don't take (they want VT_UNKNOWN), so the pointer is read here.
        fn object(value: VARIANT) -> windows::core::Result<Object> {
            const VT_UNKNOWN: u16 = 13;
            const VT_DISPATCH: u16 = 9;
            unsafe {
                let raw = &value.as_raw().Anonymous.Anonymous;
                let pointer = raw.Anonymous.punkVal;
                if (raw.vt == VT_DISPATCH || raw.vt == VT_UNKNOWN) && !pointer.is_null() {
                    if let Some(unknown) = IUnknown::from_raw_borrowed(&pointer) {
                        return Ok(Object(unknown.cast::<IDispatch>()?));
                    }
                }
            }
            Err(windows::core::Error::from_hresult(TYPE_E_TYPEMISMATCH))
        }

        fn text(value: &VARIANT) -> String {
            BSTR::try_from(value).map(|b| b.to_string()).unwrap_or_default()
        }
    }

    /// The same file as Outlook spells it? Paths compared without case and with one kind of slash.
    fn same_file(a: &str, b: &Path) -> bool {
        let norm = |s: &str| s.replace('/', "\\").trim_end_matches('\\').to_lowercase();
        let b = std::fs::canonicalize(b).map(|p| p.to_string_lossy().trim_start_matches(r"\\?\").to_string())
            .unwrap_or_else(|_| b.to_string_lossy().to_string());
        norm(a) == norm(&b) || norm(a) == norm(&b.trim_start_matches(r"\\?\").to_string())
    }

    pub fn show(file: &Path, node: u32) -> Result<(), Failure> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        }
        let clsid = unsafe { CLSIDFromProgID(windows::core::w!("Outlook.Application")) }
            .map_err(|_| fail(4, "classic Outlook isn't installed"))?;
        let app: IDispatch = unsafe { CoCreateInstance(&clsid, None, CLSCTX_LOCAL_SERVER) }
            .map_err(|err| fail(4, format!("Outlook didn't start: {err}")))?;
        let app = Object(app);
        let com = |err: windows::core::Error| fail(1, format!("Outlook: {err}"));
        let session = Object::object(app.method("GetNamespace", &[VARIANT::from(BSTR::from("MAPI"))]).map_err(com)?)
            .map_err(com)?;
        // Started by this call, Outlook isn't logged on yet: its default profile, as when it's opened from the Start menu.
        if Object::text(&session.get("CurrentProfileName").map_err(com)?).is_empty() {
            session.method("Logon", &[]).map_err(com)?;
        }

        let stores = Object::object(session.get("Stores").map_err(com)?).map_err(com)?;
        let count = i32::try_from(&stores.get("Count").map_err(com)?).unwrap_or(0);
        let mut found = None;
        for index in 1..=count {
            let Ok(store) = stores.method("Item", &[VARIANT::from(index)]).and_then(Object::object) else { continue };
            // Exchange and IMAP stores have no file, or an .ost one.
            let path = store.get("FilePath").map(|v| Object::text(&v)).unwrap_or_default();
            if !path.is_empty() && same_file(&path, file) {
                found = Some(store);
                break;
            }
        }
        let store = found.ok_or_else(|| fail(5, "this PST isn't open in Outlook"))?;

        // The EntryID: four zero bytes, the store's record key, the node id (little-endian), in hex.
        let accessor = Object::object(store.get("PropertyAccessor").map_err(com)?).map_err(com)?;
        let key = accessor.method("GetProperty", &[VARIANT::from(BSTR::from(RECORD_KEY))]).map_err(com)?;
        let key = Object::text(&accessor.method("BinaryToString", &[key]).map_err(com)?);
        let entry_id = format!("00000000{}{}", key.to_uppercase(),
                               node.to_le_bytes().iter().map(|b| format!("{b:02X}")).collect::<String>());
        let store_id = store.get("StoreID").map_err(com)?;
        let mail = session
            .method("GetItemFromID", &[VARIANT::from(BSTR::from(entry_id.as_str())), store_id])
            .and_then(Object::object)
            .map_err(|_| fail(6, "Outlook can't find this mail in the PST"))?;

        // The shell started this program from the foreground: let Outlook come in front of it.
        unsafe {
            let _ = AllowSetForegroundWindow(ASFW_ANY);
        }
        mail.method("Display", &[VARIANT::from(false)]).map_err(com)?;
        if let Ok(window) = mail.get("GetInspector").and_then(Object::object) {
            let _ = window.method("Activate", &[]);
        }
        Ok(())
    }
}
