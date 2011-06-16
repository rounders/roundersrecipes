# a set of recipes specific for linode2 server
# cap deploy:setup
# cap deploy:cold
# cap deploy

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
  set :shared_children,   %w(system log pids config)
  
  set :repository_cache, "git_cache"
  set :deploy_via, :remote_cache


  # Git settings for capistrano
  default_run_options[:pty]     = true # needed for git password prompts
  ssh_options[:forward_agent]   = true # use the keys for the person running the cap command to check out the app

  role :web, "66.228.36.175"                          # Your HTTP server, Apache/etc
  role :app, "66.228.36.175"                          # This may be the same as your `Web` server
  role :db,  "66.228.36.175", :primary => true        # This is where Rails migrations will run

  #
  # Runtime Configuration, Recipes & Callbacks
  #

  #
  # Recipes
  #
  
  after 'deploy:update_code', 'deploy:symlink_shared'
  
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

      write_database_yaml
      write_nginx_config
    end

    desc "write out nginx virtual host configuration for this app"
    task :write_nginx_config, :roles => :web do
      template_path = File.expand_path('../../../templates/nginx.erb', __FILE__)
      template = open(template_path) { |f| f.read }
      page = ERB.new(template).result(binding)
      
      put page, "#{shared_path}/#{url}", :mode => 0644
      run "sudo cp #{shared_path}/#{url} #{nginx_config_path}"
      run "cd #{nginx_config_path}/../sites-enabled;sudo ln -s ../sites-available/#{url}"
      run "sudo /etc/init.d/nginx restart"
    end
    
    desc "remove nginx virtual host configuration for this app"
    task :remove_nginx_config, :roles => :web do
      run "sudo cp #{shared_path}/#{url} #{nginx_config_path}"
      run "cd #{nginx_config_path};sudo rm ../sites-enabled/#{url};sudo rm ./#{url}"
      run "sudo /etc/init.d/nginx restart"
    end
    
    desc "write database.yml file"
    task :write_database_yaml, :roles => :web do
      template_path = File.expand_path('../../../templates/database_yml.erb', __FILE__)
      template = open(template_path) { |f| f.read }
      page = ERB.new(template).result(binding)
      put page, "#{shared_path}/config/database.yml", :mode => 0644
    end
    
    desc "symlink database.yml file"
    task :symlink_shared, :roles => :web do
      run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
    end

    desc "rake db:create"
    task :dbcreate, :roles => :db, :only => { :primary => true } do
      run_rake("db:create")
    end
    
    desc "rake db:drop" 
    task :dbdrop, :roles => :db, :only => { :primary => true } do
      run_rake("db:drop")
    end

    desc "cold deploy"
    task :cold do
      update
      dbcreate
      migrate      
    end
    
    desc "remove all application files"
    task :remove_files, :except => { :no_release => true } do
      # TODO ensure that this doesn't go terribly wrong
      if remote_file_exists?(deploy_to) && !application.empty?
        run "sudo rm -rf #{deploy_to};" 
      end
    end
    
    desc "destroy app"
    task :destroy do
      Capistrano::CLI.ui.say "This is a destructive operation and is not recoverable."
      prompt =  "if you are sure you would like to remove the app and all of its data, please type: #{application}"

      response = Capistrano::CLI.ui.ask("#{prompt} > ") do |q|
        q.overwrite = false
        q.default = nil
      end

      if response == application
        remove_nginx_config
        dbdrop
        remove_files
      end
    end



  end

end


def run_rake(cmd)
  rake = fetch(:rake, "rake")
  rails_env = fetch(:rails_env, "production")
  migrate_env = fetch(:migrate_env, "")
  migrate_target = fetch(:migrate_target, :latest)

  directory = case migrate_target.to_sym
  when :current then current_path
  when :latest  then latest_release
  else raise ArgumentError, "unknown migration target #{migrate_target.inspect}"
  end

  run "cd #{directory}; #{rake} RAILS_ENV=#{rails_env} #{migrate_env} #{cmd}"
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

def remote_file_exists?(full_path)
  'yes' == capture("if [ -d #{full_path} ]; then echo 'yes'; else echo 'no'; fi").strip
end
