//! "Index only at set hours" (Settings → Folders), as the Mac app's (DigUpKit's `IndexHours`, the app's
//! `IndexSchedule`): files are read only between two times of day, and what changed meanwhile is picked up when they
//! begin. Search works at any hour. The shell looks at the clock every half minute, so sleep and clock changes need
//! nothing of their own.

use serde::{Deserialize, Serialize};

/// From `start` to `end`, minutes since midnight, across midnight when `end` comes first. The same two: any hour.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Hours {
    pub start: u32,
    pub end: u32,
}

impl Default for Hours {
    /// 01:00–07:00: the night, when a computer that's left on has nothing else to do.
    fn default() -> Hours {
        Hours { start: 60, end: 420 }
    }
}

impl Hours {
    pub fn contains(self, minute: u32) -> bool {
        let (start, end, minute) = (self.start % 1440, self.end % 1440, minute % 1440);
        if start == end {
            true
        } else if start < end {
            (start..end).contains(&minute)
        } else {
            minute >= start || minute < end
        }
    }
}

/// Minutes since midnight now, on this computer's clock.
pub fn now() -> u32 {
    #[cfg(unix)]
    {
        // SAFETY: localtime_r fills the `tm` it's given and keeps no pointer to it.
        unsafe {
            let time = libc::time(std::ptr::null_mut());
            let mut parts: libc::tm = std::mem::zeroed();
            libc::localtime_r(&time, &mut parts);
            (parts.tm_hour * 60 + parts.tm_min) as u32
        }
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::SystemInformation::GetLocalTime;
        // SAFETY: GetLocalTime fills the SYSTEMTIME it's given.
        unsafe {
            let mut time = std::mem::zeroed();
            GetLocalTime(&mut time);
            time.wHour as u32 * 60 + time.wMinute as u32
        }
    }
}

/// "01:00"
pub fn clock(minute: u32) -> String {
    format!("{:02}:{:02}", minute % 1440 / 60, minute % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hours() {
        let night = Hours::default();
        assert!(night.contains(60) && night.contains(419) && !night.contains(420) && !night.contains(59));
        let across = Hours { start: 22 * 60, end: 6 * 60 };
        assert!(across.contains(23 * 60) && across.contains(0) && across.contains(5 * 60 + 59) && !across.contains(12 * 60));
        assert!(Hours { start: 300, end: 300 }.contains(0));
        assert_eq!(clock(60), "01:00");
        assert_eq!(clock(22 * 60 + 5), "22:05");
        assert!(now() < 1440);
    }
}
