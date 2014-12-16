%define debug_package %{nil}

Name:		kadadm
Version:	%{version}
Release:	1%{?dist}
Summary:	Keepalived administration tool

Group:		System Environment/Tools
License:	GPLv2
URL:		https://github.com/ivoronin/kadadm
Source0:	%{name}-%{version}.tar.gz

Requires:	perl, perl-Net-SNMP
BuildRequires:	redhat-rpm-config, perl

%description
kadadm is used to inspect and maintain keepalived status and configuration through SNMP.

%prep
%setup

%build
make

%install
make install DESTDIR=%{buildroot}/usr

%files
/usr/bin/kadadm
/usr/share/man/man8/kadadm.8.gz
