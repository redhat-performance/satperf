Name:          satellite-performance
Version:       1.1
Release:       1%{?dist}
Summary:       Red Hat Satellite 6 Performance testing framework and tests
License:       GPLv2
Group:         Development/Tools
URL:           https://github.com/redhat-performance/satellite-performance
Source0:       https://github.com/redhat-performance/satellite-performance/archive/%{name}-%{version}.tar.gz
BuildRoot:     %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:     noarch
Requires:      ansible


%description
Red Hat Satellite 6 Performance testing framework and tests


%prep
%setup -qc
pwd
ls -al


%build


%install
rm -rf %{buildroot}
pushd %{name}-%{version}
mkdir -p %{buildroot}/usr/%{name}
cp README.md %{buildroot}/usr/%{name}
cp LICENSE %{buildroot}/usr/%{name}
cp cleanup %{buildroot}/usr/%{name}
cp -r playbooks %{buildroot}/usr/%{name}
mkdir %{buildroot}/usr/%{name}/conf
cp conf/hosts.ini %{buildroot}/usr/%{name}/conf
cp conf/satperf.yaml %{buildroot}/usr/%{name}/conf
popd


%clean
rm -rf %{buildroot}


%files
%defattr(-,root,root,-)
/usr/%{name}


%changelog
* Wed May 31 2017 Jan Hutar <jhutar@redhat.com> 1.1-1
- Init
