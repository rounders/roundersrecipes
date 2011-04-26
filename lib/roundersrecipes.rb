
Capistrano::Configuration.instance(:must_exist).load do
  def _cset(name, *args, &block)
    unless exists?(name)
      set(name, *args, &block)
    end
  end

  # User details
  _cset :user,          'deploy'
  _cset(:group)         { user }

  # Application details
  _cset(:application)      { abort "Please specify the name of your application, set :application, 'foo'" }
  set(:url)     { "#{application}.roundersdev.com" }
  _cset(:runner)        { user }
  _cset :use_sudo,      false
  set :nginx_config_path, "/opt/local/nginx/conf/sites-available"

  # SCM settings

  set(:deploy_to)      { "/home/virtual/#{application}" }
  set :scm,           'git'
  set(:repository)      { "git@github.com:rounders/#{application}.git"}
  _cset :branch,        'master'
  _cset :deploy_via,    'remote_cache'


  # Git settings for capistrano
  default_run_options[:pty]     = true # needed for git password prompts
  ssh_options[:forward_agent]   = true # use the keys for the person running the cap command to check out the app

  if roles[:web].servers.count == 0 
    role :web, "linode2.ronincommunications.com"                          # Your HTTP server, Apache/etc
  end
  
  if roles[:app].servers.count == 0
    role :app, "linode2.ronincommunications.com"                          # This may be the same as your `Web` server
  end
  
  if roles[:db].servers.count == 0
    role :db,  "linode2.ronincommunications.com", :primary => true # This is where Rails migrations will run
  end
  

  #
  # Runtime Configuration, Recipes & Callbacks
  #

  #
  # Recipes
  #

  namespace :deploy do
    
    desc "show configuration settings"
    task :config, :roles    => :app do
      vars                  = {
        'Application'       => application,
        'Repository'        => repository,
        'Nginx Config Path' => nginx_config_path,
        'URL'               => url,
        'Deploy User'       => user,
        'web'               => roles[:web].servers.first.host,
        'app'               => roles[:app].servers.first.host,
        'db'                => roles[:db].servers.first.host,
        'use_sudo'          => use_sudo.to_s,
        'deploy_to'         => deploy_to,
        'Deploy Group'      => group,
        'scm'               => scm,
        'branch'            => branch

      }
      display_vars(vars)
    end
    
    task :start do ; end
    task :stop do ; end
    task :restart, :roles => :app, :except => { :no_release => true } do
      run "#{try_sudo} touch #{File.join(current_path,'tmp','restart.txt')}"
    end

    task :setup, :except => { :no_release => true } do
      dirs = [deploy_to, releases_path, shared_path]
      dirs += shared_children.map { |d| File.join(shared_path, d) }
      run "sudo mkdir -p #{dirs.join(' ')} && sudo chmod g+w #{dirs.join(' ')} && sudo chown #{user}: #{dirs.join(' ')}"
    end

    desc "write out nginx virtual host configuration for this app"
    task :write_nginx_config, :roles => :web do
      template_path = File.expand_path('../../templates/nginx.erb', __FILE__)
      template = open(template_path) { |f| f.read }
      page = ERB.new(template).result(binding)
      
      put page, "#{shared_path}/#{url}", :mode => 0644
      sudo "cp #{shared_path}/#{url} #{nginx_config_path}"
      sudo "cd #{nginx_config_path}/../sites-enabled;ln -s ../sites-available/#{url}"
      sudo "/etc/init.d/nginx restart"
    end
    
    task :mysql, :roles => :web do
      template_path = File.expand_path('../../templates/database_yml.erb', __FILE__)
      template = open(template_path) { |f| f.read }
      page = ERB.new(template).result(binding)

      puts page
    end

    desc "write database.yml file"
    task :write_database_yaml, :roles => :web do
      template_path = File.expand_path('../../templates/database_yml.erb', __FILE__)
      template = open(template_path) { |f| f.read }
      page = ERB.new(template).result(binding)
      put page, "#{release_path}/config/database.yml", :mode => 0644
    end

    desc "rake db:create"
    task :dbcreate, :roles => :db, :only => { :primary => true } do
      rake = fetch(:rake, "rake")
      rails_env = fetch(:rails_env, "production")
      migrate_env = fetch(:migrate_env, "")
      migrate_target = fetch(:migrate_target, :latest)

      directory = case migrate_target.to_sym
      when :current then current_path
      when :latest  then latest_release
      else raise ArgumentError, "unknown migration target #{migrate_target.inspect}"
      end

      run "cd #{directory}; #{rake} RAILS_ENV=#{rails_env} #{migrate_env} db:create"
    end

    task :cold do
      update
      dbcreate
      migrate
      start             
      write_database_yaml
      write_nginx_config
    end



  end

end


def display_vars(vars, options={})
  max_length = vars.map { |v| v[0].to_s.size }.max
  vars.keys.sort.each do |key|
    if options[:shell]
      puts "#{key}=#{vars[key]}"
    else
      spaces = ' ' * (max_length - key.to_s.size)
      puts "#{' ' * (options[:indent] || 0)}#{key}#{spaces} => #{format(vars[key], options)}"
    end
  end
end


