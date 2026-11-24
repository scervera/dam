module Dam
  # Starts scans of watched folders that are due. Dam.config.watched_folder_scheduler picks
  # how it repeats: :self_enqueue (each run enqueues the next, 30 seconds later) or
  # :external (one pass per run; the host schedules it).
  class WatchedFolderSchedulerJob < ApplicationJob
    INTERVAL = 30.seconds

    queue_as { Dam.config.queue_name(:scheduler) }

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

      enqueue_next_run if Dam.config.watched_folder_scheduler.to_sym == :self_enqueue

      Rails.logger.info "WatchedFolderSchedulerJob: Completed processing due folders"
    end

    # True when a Dam::WatchedFolderSchedulerJob is already queued or scheduled. Only
    # detectable with Sidekiq; other adapters always return false.
    def self.scheduler_pending?
      return false unless defined?(Sidekiq::ScheduledSet)

      wrapper = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
      Sidekiq::ScheduledSet.new.any? do |job|
        job.klass == wrapper && job.args.first.to_s.include?("WatchedFolderSchedulerJob")
      end || Sidekiq::Queue.new(Dam.config.queue_name(:scheduler).to_s).any? do |job|
        job.klass == wrapper && job.args.first.to_s.include?("WatchedFolderSchedulerJob")
      end
    rescue StandardError
      false
    end

    private

    # Single-flight: don't pile up duplicate schedulers.
    def enqueue_next_run
      return if self.class.scheduler_pending?

      self.class.set(wait: INTERVAL).perform_later
    end
  end
end
