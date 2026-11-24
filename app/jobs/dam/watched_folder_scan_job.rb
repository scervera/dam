module Dam
  class WatchedFolderScanJob < ApplicationJob
    queue_as { Dam.config.queue_name(:default) }

    def perform(watched_folder_id)
      Rails.logger.info "🚀 WATCHED_FOLDER_SCAN_JOB: Starting scan for folder ID: #{watched_folder_id}"
      folder = Dam::WatchedFolder.find(watched_folder_id)
      Rails.logger.info "📁 WATCHED_FOLDER_SCAN_JOB: Found folder: '#{folder.name}' at path: '#{folder.path}'"

      # Set tenant context for the job execution (required for tenant-scoped callbacks)
      Dam.current_tenant = folder.tenant
    Rails.logger.info "🏢 WATCHED_FOLDER_SCAN_JOB: Set tenant context: #{folder.tenant.name} (ID: #{folder.tenant.id})"

    # Create scan with explicit tenant assignment
    # Use build to avoid association callbacks that might not set tenant
    scan = folder.folder_scans.build(
      started_at: Time.current,
      tenant: folder.tenant
    )
    scan.save!
    Rails.logger.info "📊 WATCHED_FOLDER_SCAN_JOB: Created scan record with ID: #{scan.id}"

    begin
      # Check if folder is accessible
      unless folder.can_scan?
        raise "Folder is not accessible: #{folder.path}"
      end

      # Get all files in directory (root level only)
      files = Dir.glob(File.join(folder.path, "*"))
                 .select { |f| File.file?(f) }
                 .reject { |f| File.directory?(f) }
                 .select { |f| File.size(f) <= folder.max_file_size_bytes }

      scan.update!(files_found: files.count)

      # Process files in batches
      files.each_slice(100) do |file_batch|
        process_file_batch(file_batch, folder, scan)
      end

      # Mark scan as completed
      scan.mark_completed!
      Rails.logger.info "✅ WATCHED_FOLDER_SCAN_JOB: Scan completed successfully for folder ID: #{watched_folder_id}"

      # Update folder statistics
      folder.update!(
        last_scanned_at: scan.started_at,
        next_scan_at: folder.next_scan_time,
        total_files_found: folder.total_files_found + scan.files_found,
        total_files_processed: folder.total_files_processed + scan.files_processed,
        total_errors: folder.total_errors + scan.errors_count
      )
      Rails.logger.info "📊 WATCHED_FOLDER_SCAN_JOB: Updated folder statistics - files found: #{scan.files_found}, processed: #{scan.files_processed}, errors: #{scan.errors_count}"

      # Create completion notification
      Dam::WatchFolderNotification.create_scan_completed(
        folder,
        scan.files_processed,
        scan.errors_count
      )

    rescue => e
      Rails.logger.error "WatchedFolderScanJob failed for folder #{folder.id}: #{e.message}"
      Rails.logger.error e.backtrace.first(20).join("\n")

      scan.mark_failed!(e.message)

      # Create failure notification
      Dam::WatchFolderNotification.create_scan_failed(folder, e.message)

      # Update folder error count
      folder.increment!(:total_errors)
    ensure
      # Clear tenant context after job completes
      Dam.current_tenant = nil
    end
  end

  private

  def process_file_batch(files, folder, scan)
    files.each do |file_path|
      begin
        import_file(file_path, folder, scan)
        scan.increment_files_processed!

          # Create success notification
          Dam::WatchFolderNotification.create_file_imported(folder, file_path)

      rescue => e
        Rails.logger.error "Failed to import file #{file_path}: #{e.message}"

        scan.add_error(file_path, e.message)

          # Create failure notification
          Dam::WatchFolderNotification.create_file_import_failed(folder, file_path, e.message)
      end
    end
  end

  def import_file(file_path, folder, scan)
    Rails.logger.info "🔍 WATCHED_FOLDER_SCAN_JOB: Starting import_file for #{File.basename(file_path)}"

    # Check file size before any processing (uses configurable limit, default 1GB)
    file_size = File.size(file_path)
    max_file_size = Dam::Asset.max_file_size_limit
    Rails.logger.info "📏 WATCHED_FOLDER_SCAN_JOB: File size check - #{File.basename(file_path)}: #{file_size} bytes (#{(file_size / 1.megabyte).round(2)} MB), limit: #{(max_file_size / 1.gigabyte.to_f).round(2)} GB"

    if file_size > max_file_size
      Rails.logger.warn "📏 WATCHED_FOLDER_SCAN_JOB: Skipping oversized file #{File.basename(file_path)} (#{(file_size / 1.megabyte).round(2)} MB > #{(max_file_size / 1.gigabyte.to_f).round(2)} GB limit)"
      # Delete the oversized file to clean up the watched folder
      File.delete(file_path)
      Rails.logger.info "🗑️ WATCHED_FOLDER_SCAN_JOB: Deleted oversized file #{File.basename(file_path)} from watched folder"
      return
    end

    # Validate file type using system file command
    mime_type = `file --mime-type -b "#{file_path}"`.strip
      return unless Dam::Asset.new.accepted_types.include?(mime_type)

      # Check for existing asset by original_path (for files that haven't been moved yet)
      existing_asset = Dam::Asset.find_by(original_path: file_path)
    if existing_asset
      Rails.logger.info "🔄 WATCHED_FOLDER_SCAN_JOB: File #{File.basename(file_path)} already has an asset (ID: #{existing_asset.id}), ensuring original file is deleted"
      # Delete the original file since we already have this asset
      delete_original_file(file_path, existing_asset)
      return
    end

    # The user auto-imported files are attributed to.
    tenant_user = Dam.config.import_user_for.call(folder.tenant)

    unless tenant_user
      Rails.logger.error "❌ WATCHED_FOLDER_SCAN_JOB: No active user found for tenant #{folder.tenant.name}. Cannot create asset."
      raise "No active user found for tenant #{folder.tenant.name}"
    end

      # Create asset record with explicit tenant assignment
      asset = Dam::Asset.new(
      name: File.basename(file_path),
      original_path: file_path,
      auto_imported: true,
      watched_folder: folder,
      import_scan: scan,
      tenant: folder.tenant, # Explicitly set tenant from folder
      user: tenant_user
    )

    # Attach file using Active Storage
    # Open file and attach, ensuring it's properly saved
    File.open(file_path, "rb") do |file_io|
      asset.file.attach(
        io: file_io,
        filename: File.basename(file_path),
        content_type: mime_type
      )

      # Save the asset (this also saves the attachment)
      asset.save!

      # Verify the file was actually written to storage
      unless asset.file.attached? && asset.file.service.exist?(asset.file.key)
        raise "Failed to save file to storage: #{File.basename(file_path)}"
      end

      Rails.logger.info "✅ WATCHED_FOLDER_SCAN_JOB: File attached and verified - #{File.basename(file_path)} (key: #{asset.file.key})"
    end

    # Apply auto-tags from the watched folder
    apply_auto_tags(asset, folder)

    # After successful upload to S3, delete the original file from watcher folder
    delete_original_file(file_path, asset)

    # Generate thumbnail in background if needed
    if asset.requires_thumbnail?
      Dam::AssetThumbnailJob.perform_later(asset.id)
    end

  rescue => e
    Rails.logger.error "Error importing file #{file_path}: #{e.message}"
    raise e
  end

  def apply_auto_tags(asset, folder)
    return unless folder.has_auto_tags?

    Rails.logger.info "🏷️ WATCHED_FOLDER_SCAN_JOB: Applying auto-tags to asset #{asset.id}: #{folder.auto_tag_names.join(', ')}"

    folder.auto_tag_names.each do |tag_name|
      begin
        asset.add_tag(tag_name)
        Rails.logger.info "🏷️ WATCHED_FOLDER_SCAN_JOB: Added auto-tag '#{tag_name}' to asset #{asset.id}"
      rescue => e
        Rails.logger.error "🏷️ WATCHED_FOLDER_SCAN_JOB: Failed to add auto-tag '#{tag_name}' to asset #{asset.id}: #{e.message}"
      end
    end
  end

  def delete_original_file(file_path, asset)
    begin
      # Verify the file exists before attempting deletion
      if File.exist?(file_path)
        # Double-check that the asset was successfully saved and has a file attached
        if asset.persisted? && asset.file.attached?
          # Delete the original file from the watcher folder
          File.delete(file_path)

          Rails.logger.info "Successfully moved file #{file_path} to S3 storage and deleted original"

          # Update the asset to reflect that the original file was moved
          asset.update!(original_path: nil) # Clear the original path since file no longer exists locally

            # Create success notification for file move
            Dam::WatchFolderNotification.create_file_moved(asset.watched_folder, file_path)
        else
          Rails.logger.warn "Asset not properly saved or file not attached, skipping deletion of #{file_path}"
        end
      else
        Rails.logger.warn "Original file #{file_path} no longer exists, may have been deleted already"
      end
    rescue => e
      # Log the error but don't fail the entire import process
      Rails.logger.error "Failed to delete original file #{file_path}: #{e.message}"

        # Create a notification about the deletion failure
        Dam::WatchFolderNotification.create_file_deletion_failed(asset.watched_folder, file_path, e.message)
      end
    end
  end
end
