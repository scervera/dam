module Dam
  class WatchedFolderSchedulerJob < ApplicationJob
    queue_as :default

    def perform
      Rails.logger.info "WatchedFolderSchedulerJob: Checking for folders due for scanning"

      due_folders = Dam::WatchedFolder.active.due_for_scan
      Rails.logger.info "WatchedFolderSchedulerJob: Found #{due_folders.count} folders due for scanning"

      due_folders.each do |folder|
        Rails.logger.info "WatchedFolderSchedulerJob: Triggering scan for folder #{folder.id} (#{folder.name})"
        Dam::WatchedFolderScanJob.perform_later(folder.id)
        folder.update!(next_scan_at: folder.next_scan_time)
        Rails.logger.info "WatchedFolderSchedulerJob: Scheduled next scan for #{folder.name} at #{folder.next_scan_at}"
      end

      # Schedule the next check in 30 seconds (single-flight: avoid piling duplicate schedulers in Sidekiq).
      unless self.class.scheduler_pending?
        Dam::WatchedFolderSchedulerJob.set(wait: 30.seconds).perform_later
      end

      Rails.logger.info "WatchedFolderSchedulerJob: Completed processing due folders, scheduled next check"
    end

    # True when a Dam::WatchedFolderSchedulerJob is already queued or scheduled.
    def self.scheduler_pending?
      return false unless defined?(Sidekiq::ScheduledSet)

      wrapper = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
      Sidekiq::ScheduledSet.new.any? do |job|
        job.klass == wrapper && job.args.first.to_s.include?("WatchedFolderSchedulerJob")
      end || Sidekiq::Queue.new("default").any? do |job|
        job.klass == wrapper && job.args.first.to_s.include?("WatchedFolderSchedulerJob")
      end
    rescue StandardError
      false
    end
  end
end
