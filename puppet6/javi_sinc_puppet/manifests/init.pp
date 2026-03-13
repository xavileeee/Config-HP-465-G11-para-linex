class javi_sinc_puppet {

  # ============================
  # Dependencias
  # ============================
  package { 'dos2unix':
    ensure => installed,
  }

  # ============================
  # Instalación del script
  # ============================
  file { '/usr/local/sbin':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { '/usr/local/sbin/sinc_puppet':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    source  => 'puppet:///modules/javi_sinc_puppet/sinc_puppet.sh',
    notify  => Exec['normalize_sinc_puppet'],
  }

  exec { 'normalize_sinc_puppet':
    command     => 'bash -lc \'sed -i "1s/^\xEF\xBB\xBF//" /usr/local/sbin/sinc_puppet; dos2unix /usr/local/sbin/sinc_puppet || true; head -1 /usr/local/sbin/sinc_puppet | grep -q "/usr/bin/env bash" || sed -i "1s|^#!.*|#!/usr/bin/env bash|" /usr/local/sbin/sinc_puppet; bash -n /usr/local/sbin/sinc_puppet\'',
    refreshonly => true,
    path        => ['/bin','/usr/bin','/usr/local/bin'],
    require     => [ Package['dos2unix'], File['/usr/local/sbin/sinc_puppet'] ],
  }

  # ============================
  # Servicio systemd
  # ============================
  file { '/etc/systemd/system/sinc_puppet.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @(UNIT_CONTENT)
      [Unit]
      Description=Sincroniza Puppet SSL/CA y ejecuta puppet agent -tv al arranque
      Wants=network-online.target
      After=network-online.target NetworkManager-wait-online.service systemd-networkd-wait-online.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/sinc_puppet
      User=root
      Group=root
      StartLimitIntervalSec=600
      StartLimitBurst=5

      [Install]
      WantedBy=multi-user.target
      UNIT_CONTENT
    ,
    notify  => Exec['systemd-daemon-reload'],
    require => File['/usr/local/sbin/sinc_puppet'],
  }

  # ============================
  # Timer systemd
  # ============================
  file { '/etc/systemd/system/sinc_puppet.timer':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @(TIMER_CONTENT)
      [Unit]
      Description=Lanza sinc_puppet al boot (demora y persistencia)

      [Timer]
      OnBootSec=90s
      Unit=sinc_puppet.service
      Persistent=true

      [Install]
      WantedBy=timers.target
      TIMER_CONTENT
    ,
    notify  => Exec['systemd-daemon-reload'],
    require => File['/etc/systemd/system/sinc_puppet.service'],
  }

  # ============================
  # Recarga systemd y activación
  # ============================
  exec { 'systemd-daemon-reload':
    command     => '/bin/systemctl daemon-reload',
    refreshonly => true,
    path        => ['/bin','/usr/bin'],
  }

  service { 'sinc_puppet.timer':
    ensure    => running,
    enable    => true,
    require   => [ File['/etc/systemd/system/sinc_puppet.timer'], Exec['systemd-daemon-reload'] ],
    subscribe => File['/etc/systemd/system/sinc_puppet.timer'],
  }

  service { 'sinc_puppet.service':
    ensure    => stopped,   # oneshot: no permanece activo
    enable    => true,      # symlink habilitado
    require   => [ File['/etc/systemd/system/sinc_puppet.service'], Exec['systemd-daemon-reload'] ],
    subscribe => File['/etc/systemd/system/sinc_puppet.service'],
  }

}
