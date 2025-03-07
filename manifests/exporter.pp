# Sets up target nodes with nessary services and access for RSAN
# When Applied to the Infrastruture Agent Node group, 
# Will dynamically configure all matching nodes to allow access to key elements of Puppet Enterprise to the RSAN node
# @param [Array] rsan_importer_ips
#   An array of rsan ip addresses
#   Defaults to the output of a PuppetDB query
# @param [Optional[String]] rsan_host
#   The certname of the rsan node
# @param [Optional[String]] pg_user
#   The postgres user PE uses 
# @param [Optional[String]] pg_group
#   The postgres group PE uses the default is pg_user
# @param [Optional[String]] pg_psql_path
#   The path to the postgres binary in pe
# @param [Boolean] nfsmount
#   Trigger to turn NFS Mounts On Or Off
# @example
#   include rsan::exporter
class rsan::exporter (
  Array $rsan_importer_ips = rsan::get_rsan_importer_ips(),
  Optional[String] $rsan_host = undef,
  Optional[String] $pg_user = 'pe-postgres',
  Optional[String] $pg_group = $pg_user,
  Optional[String] $pg_psql_path = '/opt/puppetlabs/server/bin/psql',
  Boolean $nfsmount = true,
){

########################1.  Export Logging Function######################
# Need to determine automatically the Network Fact IP for the RSAN::importer node automatically, applies to all infrastructure nodes
#########################################################################



  class { '::nfs':
    server_enabled => true
  }


  $ensure = $nfsmount ? {
    true  => 'mounted',
    false => 'absent',
  }


# Convert the array of RSAN IP address into an list of clients with options for the NFS export.
# This reduce will return a string of space deliminated IP addresses with the NFS options.
# For example, the output for ['1.2.3.4'] is " 1.2.3.4(ro,insecure,async,no_root_squash)"
# For example, the output for ['1.2.3.4', '5.6.7.8'] is 
#   " 1.2.3.4(ro,insecure,async,no_root_squash) 5.6.7.8(ro,insecure,async,no_root_squash)"

  $_rsan_clients = $rsan_importer_ips.reduce('') |$memo, $ip| {
    "${memo} ${ip}(ro,insecure,async,no_root_squash)"
  }
  $clients = "${_rsan_clients} localhost(ro)"

  nfs::server::export{ '/var/log/':
    ensure      => $ensure,
    clients     => $clients,
    mount       => "/var/pesupport/${facts['fqdn']}/log",
    options_nfs => 'tcp,nolock,rsize=32768,wsize=32768,soft,noatime,actimeo=3,retrans=1',
    nfstag      => 'rsan',
  }
  nfs::server::export{ '/opt/puppetlabs/':
    ensure      => $ensure,
    clients     => $clients,
    mount       => "/var/pesupport/${facts['fqdn']}/opt",
    options_nfs => 'tcp,nolock,rsize=32768,wsize=32768,soft,noatime,actimeo=3,retrans=1',
    nfstag      => 'rsan',
  }
  nfs::server::export{ '/etc/puppetlabs/':
    ensure      => $ensure,
    clients     => $clients,
    mount       => "/var/pesupport/${facts['fqdn']}/etc",
    options_nfs => 'tcp,nolock,rsize=32768,wsize=32768,soft,noatime,actimeo=3,retrans=1',
    nfstag      => 'rsan',
  }

  ######################2. Metrics Dash Board deployment ###############
  # Assuming use of puppet metrics dashboard for telemetry all nodes need
  # include puppet_metrics_dashboard::profile::master::install
  ###################################################################

  if $facts['pe_server_version'] != undef {
    include puppet_metrics_dashboard::profile::master::install
  }

  #####################3. RSANpostgres command access ######################
  # Determine if node is pe_postgres host and conditionally apply Select Access for the RSAN node cert to all PE databases
  # and conditionally apply include puppet_metrics_dashboard::profile::master::postgres_access
  ######################################################################

  if $facts['pe_postgresql_info'] != undef and $facts['pe_postgresql_info']['installed_server_version'] != '' {

    include puppet_metrics_dashboard::profile::master::postgres_access

    if $rsan_host {
      $_rsan_host = $rsan_host
    } else {
      $_query = puppetdb_query('resources[certname] {
        type = "Class" and
        title = "Rsan::Importer" and             
        nodes {
          deactivated is null and
          expired is null
        }
        order by certname asc
        limit 1
      }')
      unless $_query.empty {
        $_rsan_host = $_query[0]['certname']
      }
    }

    # If $rsan_host is not defined and the query fails to find a rsan  host, issue a warning.

    if $_rsan_host == undef {

      notify { 'You must specify rsan_host (or apply the rsan class to an agent) to enable access.': }

    } else {

      pe_postgresql::server::role { 'rsan': }

      if $facts['pe_postgresql_info']['installed_server_version'] {
        $postgres_version = $facts['pe_postgresql_info']['installed_server_version']
      } else {
        $postgres_version = '9.4'
      }

      $dbs = ['pe-activity', 'pe-classifier', 'pe-inventory', 'pe-puppetdb', 'pe-rbac', 'pe-orchestrator']
      $dbs.each |$db|{
        pe_postgresql::server::database_grant { "CONNECT to rsan for ${db}":
          privilege => 'CONNECT',
          db        => $db,
          role      => 'rsan',
          require   => Pe_postgresql::Server::Role['rsan']
        }

        $grant_cmd = "GRANT SELECT ON ALL TABLES IN SCHEMA \"public\" TO rsan"
        pe_postgresql_psql { "${grant_cmd} on ${db}":
          command    => $grant_cmd,
          db         => $db,
          port       => $pe_postgresql::server::port,
          psql_user  => $pg_user,
          psql_group => $pg_group,
          psql_path  => $pg_psql_path,
          unless     => "SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE privilege_type = 'SELECT' AND grantee = 'rsan'",
          require    => [
            Class['pe_postgresql::server'],
            Pe_postgresql::Server::Role['rsan']
          ]
        }

        puppet_enterprise::pg::cert_allowlist_entry { "allow-rsan-access for ${db}":
          user                          => 'rsan',
          database                      => $db,
          allowed_client_certname       => $_rsan_host,
          pg_ident_conf_path            => "/opt/puppetlabs/server/data/postgresql/${postgres_version}/data/pg_ident.conf",
          ip_mask_allow_all_users_ssl   => '0.0.0.0/0',
          ipv6_mask_allow_all_users_ssl => '::/0',
        }
      }
    }
  }
}
