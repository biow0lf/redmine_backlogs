class RbStory < Issue
  unloadable

  acts_as_list

  def self.condition(project_id, sprint_id, extras = [])
    if Issue.respond_to? :visible_condition
      visible = Issue.visible_condition(User.current, :project => Project.find(project_id))
    else
      visible = Project.allowed_to_condition(User.current, :view_issues)
    end
    visible = '1=1' # unless visible

    if sprint_id.nil?
      c = ["
        project_id = ?
        AND tracker_id IN (?)
        AND fixed_version_id IS NULL
        AND is_closed = ? AND #{visible}", project_id, RbStory.trackers, false]
    else
      unless sprint_id.kind_of? Array
        sprint_id = [sprint_id]
      end
      c = ["
        project_id = ?
        AND tracker_id IN (?)
        AND fixed_version_id IN (?) AND #{visible}",
        project_id, RbStory.trackers, sprint_id]
    end

    if extras.size > 0
      c[0] += ' ' + extras.shift
      c += extras
    end

    c
  end

  # this forces NULLS-LAST ordering
  ORDER = 'case when issues.position is null then 1 else 0 end ASC, case when issues.position is NULL then issues.id else issues.position end ASC'

  def self.backlog(project_id, sprint_id, options = {})
    stories = []

    RbStory.find(:all,
                 :order => RbStory::ORDER,
                 :conditions => RbStory.condition(project_id, sprint_id),
                 :joins => [:status, :project],
                 :limit => options[:limit]).each_with_index do |story, i|
      story.rank = i + 1
      stories << story
    end

    stories
  end

  def self.product_backlog(project, limit = nil)
    RbStory.backlog(project.id, nil, :limit => limit)
  end

  def self.sprint_backlog(sprint, options = {})
    RbStory.backlog(sprint.project.id, sprint.id, options)
  end

  def self.backlogs_by_sprint(project, sprints, options = {})
    ret = RbStory.backlog(project.id, sprints.map { |s| s.id }, options)
    sprint_of = {}
    ret.each do |backlog|
      sprint_of[backlog.fixed_version_id] ||= []
      sprint_of[backlog.fixed_version_id].push(backlog)
    end
    sprint_of
  end

  def self.stories_open(project)
    stories = []

    RbStory.find(:all,
                 :order => RbStory::ORDER,
                 :conditions => ["project_id = ? AND tracker_id IN (?) AND is_closed = ?", project.id, RbStory.trackers, false],
                 :joins => :status).each_with_index do |story, i|
      story.rank = i + 1
      stories << story
    end
    stories
  end

  def self.create_and_position(params)
    attribs = params.select { |k, v| k != 'prev_id' and k != 'id' and RbStory.column_names.include?(k) }
    attribs = Hash[*attribs.flatten]
    s = RbStory.new(attribs)
    s.save!
    # indicate that this a new story. saving will set position to 1 and the move_after code needs position = nil to make an insert operation.
    s.position = nil
    s.move_after(params['prev_id'])
    s
  end

  def self.find_all_updated_since(since, project_id)
    find(:all,
         :conditions => ["project_id = ? AND updated_on > ? AND tracker_id IN (?)", project_id, Time.parse(since), trackers],
         :order => "updated_on ASC")
  end

  def self.trackers(options = {})
    # legacy
    options = { :type => options } if options.is_a?(Symbol)

    # somewhere early in the initialization process during first-time migration this gets called when the table doesn't yet exist
    trackers = []
    if ActiveRecord::Base.connection.tables.include?('settings')
      trackers = Backlogs.setting[:story_trackers]
      trackers = [] if trackers.blank?
    end

    trackers = Tracker.find_all_by_id(trackers)
    trackers = trackers & options[:project].trackers if options[:project]
    trackers = trackers.sort_by { |t| [t.position] }

    case options[:type]
    when :trackers
      return trackers
    when :array, nil
      return trackers.collect { |t| t.id }
    when :string
      return trackers.collect { |t| t.id.to_s }.join(',')
    else
      raise "Unexpected return type #{options[:type].inspect}"
    end
  end

  def tasks
    RbTask.tasks_for(self.id)
  end

  def move_after(prev_id)
    # remove so the potential 'prev' has a correct position
    RbStory.connection.execute("UPDATE issues SET position = position - 1 WHERE position > #{position}") unless position.nil?

    if prev_id.to_s == ''
      prev = nil
    else
      prev = RbStory.find(prev_id)
    end

    # if prev is the first story, move current to the 1st position
    if prev.blank?
      RbStory.connection.execute("UPDATE issues SET position = position + 1")
      # do stories start at position 1? rake task fix_positions indicates that.
      RbStory.connection.execute("UPDATE issues SET position = 1 WHERE id = #{id}")

    # if its predecessor has no position (shouldn't happen
    # - but happens if we add many stories using "new issues" and begin sorting),
    # make current the last positioned story the last story
    elsif prev.position.nil?
      new_pos = 0
      RbStory.connection.execute("SELECT COALESCE(MAX(position) + 1, 0) FROM issues").each do |row|
        row = row.values if row.is_a?(Hash)
        new_pos = row[0]
      end
      RbStory.connection.execute("UPDATE issues SET position = #{new_pos} WHERE id = #{id}")

    # there's a valid predecessor
    else
      RbStory.connection.execute("UPDATE issues SET position = position + 1 WHERE position > #{prev.position}")
      RbStory.connection.execute("UPDATE issues SET position = #{prev.position} + 1 WHERE id = #{id}")
    end
  end

  def set_points(p)
    self.init_journal(User.current)

    if p.blank? || p == '-'
      self.update_attribute(:story_points, nil)
      return
    end

    if p.downcase == 's'
      self.update_attribute(:story_points, 0)
      return
    end

    p = Integer(p)
    if p >= 0
      self.update_attribute(:story_points, p)
      return
    end
  end

  def points_display(notsized = '-')
    # For reasons I have yet to uncover, activerecord will
    # sometimes return numbers as Fixnums that lack the nil?
    # method. Comparing to nil should be safe.
    return notsized if story_points == nil || story_points.blank?
    return 'S' if story_points == 0
    story_points.to_s
  end

  def task_status
    closed = 0
    open = 0
    self.descendants.each do |task|
      if task.closed?
        closed += 1
      else
        open += 1
      end
    end
    { :open => open, :closed => closed }
  end

  def update_and_position!(params)
    attribs = params.select { |k, v| k != 'id' && k != 'project_id' && RbStory.column_names.include?(k) }
    attribs = Hash[*attribs.flatten]
    result = self.becomes(Issue).journalized_update_attributes attribs
    if result and params[:prev]
      move_after(params[:prev])
    end
    result
  end

  def rank=(r)
    @rank = r
  end

  def rank
    if self.position.blank?
      extras = ['AND ((issues.position IS NULL AND issues.id <= ?) OR NOT issues.position IS NULL)', self.id]
    else
      extras = ['AND NOT issues.position IS NULL AND issues.position <= ?', self.position]
    end

    @rank ||= Issue.count(:conditions => RbStory.condition(self.project.id, self.fixed_version_id, extras), :joins => [:status, :project])

    @rank
  end

  def self.at_rank(project_id, sprint_id, rank)
    RbStory.find(:first,
                 :order => RbStory::ORDER,
                 :conditions => RbStory.condition(project_id, sprint_id),
                 :joins => [:status, :project],
                 :limit => 1,
                 :offset => rank - 1)
  end

  def burndown(sprint = nil)
    return nil unless self.is_story?
    sprint ||= self.fixed_version.becomes(RbSprint) if self.fixed_version
    return nil if sprint.nil? || !sprint.has_burndown?

    return Rails.cache.fetch("RbIssue(#{self.id}@#{self.updated_on}).burndown(#{sprint.id}@#{sprint.updated_on}-#{[Date.today, sprint.effective_date].min})") {
      bd = {}

      if sprint.has_burndown?
        days = sprint.days(:active)

        status = history(:status_id, days).collect do |s|
          begin
            s ? IssueStatus.find(s) : nil
          rescue ActiveRecord::RecordNotFound
            nil
          end
        end

        series = Backlogs::MergedArray.new
        series.merge(:in_sprint => history(:fixed_version_id, days).collect { |s| s == sprint.id })
        series.merge(:points => history(:story_points, days))
        series.merge(:open => status.collect { |s| s ? !s.is_closed? : false })
        series.merge(:accepted => status.collect { |s| s ? (s.backlog_is?(:success)) : false })
        series.merge(:hours => ([0] * (days.size + 1)))

        tasks.each { |task| series.add(:hours => task.burndown(sprint)) }

        series.each do |datapoint|
          if datapoint.in_sprint
            datapoint.hours = 0 unless datapoint.open
            datapoint.points_accepted = (datapoint.accepted ? datapoint.points : nil)
            datapoint.points_resolved = (datapoint.accepted || datapoint.hours.to_f == 0.0 ? datapoint.points : nil)
          else
            datapoint.nilify
            datapoint.points_accepted = nil
            datapoint.points_resolved = nil
          end
        end

        # collect points on this sprint
        bd[:points] = series.series(:points)
        bd[:points_accepted] = series.series(:points_accepted)
        bd[:points_resolved] = series.series(:points_resolved)
        bd[:hours] = series.collect { |datapoint| datapoint.open ? datapoint.hours : nil }
      end

      bd
    }
  end
end
