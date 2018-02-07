class {{ content_puppet_module_name }} {
  file { "{{ content_puppet_module_file }}":
    ensure => file,
    mode   => "755",
    owner  => root,
    group  => root,
    content => "{{ content_puppet_module_file_content }}",
  }
}
