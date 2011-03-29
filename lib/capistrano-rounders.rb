

Capistrano::Configuration.instance(:must_exist).load do

  require 'capistrano/recipes/deploy/scm'
  require 'capistrano/recipes/deploy/strategy'


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
  _cset :nginx_config_path, "/opt/local/nginx/conf/sites-available"

  # SCM settings
  _cset(:deploy_to)        { "/home/virtual/#{application}" }
  _cset :scm,           'git'
  set(:repository)      { "git@github.com:rounders/#{application}.git"}
  _cset :branch,        'master'
  _cset :deploy_via,    'remote_cache'


  # Git settings for capistrano
  default_run_options[:pty]     = true # needed for git password prompts
  ssh_options[:forward_agent]   = true # use the keys for the person running the cap command to check out the app

  #
  # Runtime Configuration, Recipes & Callbacks
  #

  #
  # Recipes
  #

  namespace :deploy do
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
      template =<<EOF
      server {
        listen       80;
        server_name  #{url};
        #charset koi8-r;
        #access_log  logs/host.access.log  main;
        location / {
          root   #{current_path}/public;
          index  index.html index.htm;
          passenger_enabled on;
        }
        #error_page  404              /404.html;
        # redirect server error pages to the static page /50x.html
        #
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
          root   html;
        }

      }
EOF

      page = ERB.new(template).result(binding)
      put page, "#{shared_path}/#{url}", :mode => 0644
      sudo "cp #{shared_path}/#{url} #{nginx_config_path}"
      sudo "cd #{nginx_config_path}/../sites-enabled;ln -s ../sites-available/#{url}"
      sudo "/etc/init.d/nginx restart"
    end

    desc "write database.yml file"
    task :write_database_yaml, :roles => :web do
      template =<<EOF      
      production:
      adapter: mysql2
      encoding: utf8
      database: #{application}
      username: root
      password: 44bdbac
EOF

      page = ERB.new(template).result(binding) 
      put page, "#{release_path}/config/database.yml", :mode => 0644
    end

    desc "monkey"

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


