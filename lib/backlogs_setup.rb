require 'rubygems' if RUBY_VERSION < '1.9'
require 'yaml'
require 'singleton'

module Backlogs
  def version
    root = File.expand_path('..', File.dirname(__FILE__))
    git = File.join(root, '.git')
    v = Redmine::Plugin.find(:redmine_backlogs).version

    g = nil
    if File.directory?(git)
      Dir.chdir(root)
      g = `git log | head -1 | awk '{print $2}'`
      g.strip!
      g = "(#{g})"
    end

    v = [v, g].compact.join(' ')
    v = '?' if v == ''
    v
  end
  module_function :version

  def platform_support(raise_error = false)
    case platform
    when :redmine
      supported = [1,4]
      unsupported = [1,3]
    when :chiliproject
      supported = [3,1,0]
      unsupported = nil
    else
      raise "Unsupported platform #{platform}"
    end

    return "#{Redmine::VERSION}" if Redmine::VERSION.to_a[0,supported.length] == supported
    return "#{Redmine::VERSION} (unsupported but might work, please upgrade to #{supported.collect{|d| d.to_s}.join('.')}" if unsupported && Redmine::VERSION.to_a[0,unsupported.length] == unsupported
    msg = "#{Redmine::VERSION} (NOT SUPPORTED; please install #{platform} #{supported.collect{|d| d.to_s}.join('.')})"
    raise msg if raise_error
    return msg
  end
  module_function :platform_support

  def os
    return :windows if RUBY_PLATFORM =~ /cygwin|windows|mswin|mingw|bccwin|wince|emx/
    return :unix if RUBY_PLATFORM =~ /darwin|linux/
    return :java if RUBY_PLATFORM =~ /java/
    nil
  end
  module_function :os

  def gems
    installed = Hash[*(['system_timer', 'nokogiri', 'open-uri/cached', 'holidays', 'icalendar', 'prawn'].collect { |gem| [gem, false] }.flatten)]
    installed.delete('system_timer') unless os == :unix && RUBY_VERSION =~ /^1\.8\./
    installed.keys.each do |gem|
      begin
        require gem
        installed[gem] = true
      rescue LoadError
      end
    end
    installed
  end
  module_function :gems

  def trackers
    { :task => !RbTask.tracker.nil?,
      :story => RbStory.trackers.size != 0,
      :default_priority => !IssuePriority.default.nil?
    }
  end
  module_function :trackers

  def task_workflow(project)
    return true if User.current.admin?
    return false unless RbTask.tracker

    roles = User.current.roles_for_project(@project)
    tracker = Tracker.find(RbTask.tracker)

    [false, true].each do |creator|
      [false, true].each do |assignee|
        tracker.issue_statuses.each do |status|
          status.new_statuses_allowed_to(roles, tracker, creator, assignee).each do |s|
            return true
          end
        end
      end
    end
  end
  module_function :task_workflow

  def migrated?
    available = Dir[File.join(File.dirname(__FILE__), '../db/migrate/*.rb')].collect { |m| Integer(File.basename(m).split('_')[0].gsub(/^0+/, '')) }.sort
    return true if available.size == 0
    available = available[-1]

    ran = []
    Setting.connection.execute("SELECT version FROM schema_migrations WHERE version LIKE '%-redmine_backlogs'").each do |m|
      ran << Integer((m.is_a?(Hash) ? m.values : m)[0].split('-')[0])
    end
    return false if ran.size == 0
    ran = ran.sort[-1]

    ran >= available
  end
  module_function :migrated?

  def configured?(project = nil)
    return false if Backlogs.gems.values.reject { |installed| installed }.size > 0
    return false if Backlogs.trackers.values.reject { |configured| configured }.size > 0
    return false unless Backlogs.migrated?
    return false unless project.nil? || project.enabled_module_names.include?("backlogs")
    true
  end
  module_function :configured?

  def platform
    unless @platform
      begin
        ChiliProject::VERSION
        @platform = :chiliproject
      rescue NameError
        @platform = :redmine
      end
    end
    return @platform
  end
  module_function :platform

  class SettingsProxy
    include Singleton

    def [](key)
      return safe_load[key]
    end

    def []=(key, value)
      settings = safe_load
      settings[key] = value
      Setting.plugin_redmine_backlogs = settings
    end

    def to_h
      h = safe_load
      h.freeze
      h
    end

    private

    def safe_load
      settings = Setting.plugin_redmine_backlogs.dup
      if settings.is_a?(String)
        RAILS_DEFAULT_LOGGER.error "Unable to load settings"
        return {}
      end
      settings
    end
  end

  def setting
    SettingsProxy.instance
  end
  module_function :setting
  def settings
    SettingsProxy.instance.to_h
  end
  module_function :settings
end
