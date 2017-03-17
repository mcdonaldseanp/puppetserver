test_name 'Default metrics are exported to graphite server'

graphite = agents.find { |agent| agent['platform'] =~ /el-6-x86_64/ }
skip_test 'This test requires an el6 agent' unless graphite

puppetserver_conf_file = options['puppetserver-config']
metrics_conf_file = "#{options['puppetserver-confdir']}/metrics.conf"
puppetservice = options['puppetservice']
environments_dir = "/etc/puppetlabs/code/environments"
manifests_dir = "#{environments_dir}/production/manifests"
sitepp = "#{manifests_dir}/site.pp"

step 'Backup puppetserver config files' do
  on master, "cp -f #{puppetserver_conf_file} #{puppetserver_conf_file}.bak"
  on master, "cp -f #{metrics_conf_file} #{metrics_conf_file}.bak"
end

teardown do
  on master, "mv -f #{puppetserver_conf_file}.bak #{puppetserver_conf_file}"
  on master, "mv #{metrics_conf_file}.bak #{metrics_conf_file}"
  if !master.is_pe?
    on master, "rm -f #{sitepp}"
  end
  bounce_service(master, puppetservice)
end

if !master.is_pe?
  step 'Configuring manifest for exercising function metrics in agent run' do
    on master, "mkdir -p #{manifests_dir}"
    create_remote_file(master, sitepp, <<SITEPP)
notify { 'hello':
  message => generate("/bin/echo", "world")
}
SITEPP
    on(master, "chown -R puppet #{environments_dir}")
  end
end

step 'Install graphite (and grafana)' do
  tmp_module_dir = agent.tmpdir('collect_default_metrics')

  on(graphite, "puppet module install cprice404-grafanadash --codedir #{tmp_module_dir}")
  on(graphite, "puppet apply -e \"include grafanadash::dev\" --codedir #{tmp_module_dir}")
end

step 'Enable graphite and profiler metrics in puppetserver configuration' do
  metrics_config =
      {"metrics" =>
           {"server-id" => master.hostname,
            "registries" =>
                {"puppetserver" =>
                     {"reporters" =>
                          {"graphite" =>
                               {"enabled" => true,
                                "update-interval-seconds" => 1}}}},
            "reporters" =>
                {"graphite" =>
                     {"host" => agent.hostname,
                      "port" => 2003,
                      "update-interval-seconds" => 1}}}};

  modify_tk_config(master, metrics_conf_file, metrics_config)

  profiler_config = {"profiler" => {"enabled" => true}}
  modify_tk_config(master, puppetserver_conf_file, profiler_config)

  bounce_service(master, puppetservice)
end

step 'Generate some metrics by performing an agent run' do
  on(graphite, puppet("agent -t --no-use_cached_catalog --server #{master}"),
                       :acceptable_exit_codes => [0, 2])
end

default_metrics = build_default_metrics
full_results = Hash.new

step 'Query the graphite system for the default list of metrics' do
  full_results = query_metrics(master.hostname, graphite, default_metrics)

  puts "List of collected metrics:"
  full_results.each do |key, val|
    logger.info "#{key} => #{val[-1]}"
  end
end

step 'Validate that all metrics expected to be exported are in graphite server' do
  missing_metrics = build_missing_metrics_list(master, default_metrics, full_results)

  if missing_metrics.size != 0
    missing_metrics.each do |mm|
      logger.error "Expected to find a value for missing metric #{mm}"
    end
    assert(false, "FAIL: There are missing metrics.")
  end
end
