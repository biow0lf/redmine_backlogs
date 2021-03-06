require 'benchmark'

class FixMissingJournal < ActiveRecord::Migration
  def self.up
    if Backlogs.platform == :redmine
      Issue.find(:all, :conditions => ['tracker_id = ?', RbTask.tracker]).each do |task|
        jd = JournalDetail.find(:first,
                                :conditions => ["property = 'attr' AND prop_key = 'estimated_hours' AND journalized_type = 'Issue' AND journalized_id = ?", task.id],
                                :joins => :journal,
                                :order => "journals.created_on DESC")
        if jd && jd.value.to_f != task.estimated_hours
          nj = Journal.new
          nj.journalized = task
          nj.user = jd.journal.user
          nj.created_on = task.updated_on

          njd = JournalDetail.new
          njd.property = 'attr'
          njd.prop_key = 'estimated_hours'
          njd.old_value = jd.value
          njd.value = task.estimated_hours.to_s

          nj.details << njd

          nj.save!
        end
      end
    end
  end

  def self.down
    raise ActiveRecord::IrreversibleMigration
  end
end
