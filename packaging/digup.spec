Name:           digup
Version:        %{version}
Release:        1%{?dist}
Summary:        Search your files by meaning
License:        MIT
URL:            https://github.com/ARahim3/DigUp
Source0:        digup-%{version}-x86_64.tar.gz
BuildArch:      x86_64
Requires:       sqlite-libs, ffmpeg, poppler-utils

%description
DigUp indexes pictures, PDFs, documents, audio, video and code with
Google DeepMind's EmbeddingGemma 2 and finds them from a description
in your own words. Everything runs on your machine.

%prep

%build

%install
install -Dm755 usr/bin/digup %{buildroot}%{_bindir}/digup
install -Dm644 usr/share/doc/digup/README.md %{buildroot}%{_docdir}/digup/README.md
install -Dm644 usr/share/doc/digup/LICENSE %{buildroot}%{_licensedir}/digup/LICENSE

%files
%{_bindir}/digup
%{_docdir}/digup/README.md
%{_licensedir}/digup/LICENSE

%changelog
