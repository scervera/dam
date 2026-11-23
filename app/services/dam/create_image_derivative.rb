require "vips"
require "pathname"
require "tempfile"

module Dam
  class CreateImageDerivative
    class Error < StandardError; end
    class ValidationError < Error; end

    MAX_DIMENSION = 12_000

    attr_reader :source_asset, :actor, :params

    def initialize(source_asset:, actor:, params: {})
      @source_asset = source_asset
      @actor = actor
      @params = (params || {}).deep_symbolize_keys
    end

    def call
      validate_source_asset!

      source_file = download_source_file
      image = Vips::Image.new_from_file(source_file.path, access: :sequential)
      image = image.autorot

      source_dimensions = { width: image.width.to_i, height: image.height.to_i }
      operations = normalize_operations(source_dimensions)
      image = apply_operations(image, operations)

      output = normalize_output
      output_extension_name = output_extension(output[:format])
      output_file = Tempfile.new([ "dam-derivative", output_extension_name ])
      output_file.binmode
      write_output_image!(image, output_file.path, output)
      output_file.flush

      derivative_asset = persist_derivative_asset!(
        output_file: output_file,
        source_dimensions: source_dimensions,
        result_dimensions: { width: image.width.to_i, height: image.height.to_i },
        operations: operations,
        output: output
      )

      derivative_asset
    rescue Vips::Error => e
      raise ValidationError, "Image processing failed: #{e.message}"
    ensure
      source_file&.close!
      output_file&.close!
    end

    private

    def validate_source_asset!
      raise ValidationError, "Source asset is required" unless source_asset
      raise ValidationError, "Actor is required" unless actor
      raise ValidationError, "Only image assets can be edited" unless source_asset.image?
      raise ValidationError, "Source image file is not attached" unless source_asset.file.attached?

      actor_tenant_id =
        if actor.respond_to?(:tenant_id) && actor.tenant_id.present?
          actor.tenant_id
        elsif actor.respond_to?(:tenant) && actor.tenant
          actor.tenant.id
        end

      if actor_tenant_id.present? && actor_tenant_id != source_asset.tenant_id
        raise ValidationError, "Actor and source must belong to the same tenant"
      end
    end

    def download_source_file
      extension = File.extname(source_asset.filename.to_s)
      tempfile = Tempfile.new([ "dam-source", extension.presence || ".img" ])
      tempfile.binmode
      tempfile.write(source_asset.file.download)
      tempfile.rewind
      tempfile
    end

    def normalize_operations(source_dimensions)
      operations = params.fetch(:operations, {}).to_h.deep_symbolize_keys

      crop = normalize_crop(operations[:crop], source_dimensions)
      working_dimensions = crop ? { width: crop[:width], height: crop[:height] } : source_dimensions.dup

      resize = normalize_resize(operations[:resize], working_dimensions)
      rotate = normalize_rotation(operations[:rotate])

      {
        crop: crop,
        resize: resize,
        rotate: rotate
      }.compact
    end

    def normalize_crop(crop, source_dimensions)
      return nil if crop.blank?

      x = integer_param(crop[:x], default: 0)
      y = integer_param(crop[:y], default: 0)
      width = integer_param(crop[:width], default: source_dimensions[:width])
      height = integer_param(crop[:height], default: source_dimensions[:height])

      width = width.clamp(1, source_dimensions[:width])
      height = height.clamp(1, source_dimensions[:height])
      x = x.clamp(0, source_dimensions[:width] - 1)
      y = y.clamp(0, source_dimensions[:height] - 1)

      width = [ width, source_dimensions[:width] - x ].min
      height = [ height, source_dimensions[:height] - y ].min

      {
        x: x,
        y: y,
        width: width,
        height: height
      }
    end

    def normalize_resize(resize, current_dimensions)
      return nil if resize.blank?

      width = integer_param(resize[:width], default: current_dimensions[:width])
      height = integer_param(resize[:height], default: current_dimensions[:height])
      mode = resize[:mode].to_s.presence_in(%w[limit fill exact]) || "exact"

      width = width.clamp(1, MAX_DIMENSION)
      height = height.clamp(1, MAX_DIMENSION)

      {
        width: width,
        height: height,
        mode: mode
      }
    end

    def normalize_rotation(rotate)
      return nil if rotate.blank?

      degrees = float_param(rotate[:degrees], default: 0.0)
      return nil if degrees.zero?

      { degrees: degrees }
    end

    def normalize_output
      output = params.fetch(:output, {}).to_h.deep_symbolize_keys
      format = output[:format].to_s.downcase.presence
      format = nil if format == "keep"

      if format.present? && !%w[jpg jpeg png webp].include?(format)
        raise ValidationError, "Output format must be jpg, png, or webp"
      end

      quality = output[:quality].present? ? integer_param(output[:quality], default: 90).clamp(1, 100) : nil

      {
        format: format,
        quality: quality
      }.compact
    end

    def apply_operations(image, operations)
      processed = image

      if operations[:crop]
        crop = operations[:crop]
        processed = processed.crop(crop[:x], crop[:y], crop[:width], crop[:height])
      end

      if operations[:resize]
        resize = operations[:resize]
        processed = apply_resize(processed, resize)
      end

      if operations[:rotate]
        processed = apply_rotation(processed, operations[:rotate][:degrees])
      end

      processed
    end

    def apply_resize(image, resize)
      target_width = resize[:width].to_i
      target_height = resize[:height].to_i
      mode = resize[:mode].to_s

      case mode
      when "fill"
        scale = [
          target_width.to_f / image.width.to_f,
          target_height.to_f / image.height.to_f
        ].max
        resized = image.resize(scale)

        crop_width = [ target_width, resized.width ].min
        crop_height = [ target_height, resized.height ].min
        left = ((resized.width - crop_width) / 2.0).floor
        top = ((resized.height - crop_height) / 2.0).floor

        filled = resized.crop(left, top, crop_width, crop_height)
        if crop_width == target_width && crop_height == target_height
          filled
        else
          scale_x = target_width.to_f / filled.width.to_f
          scale_y = target_height.to_f / filled.height.to_f
          filled.resize(scale_x, vscale: scale_y)
        end
      when "limit"
        scale = [
          target_width.to_f / image.width.to_f,
          target_height.to_f / image.height.to_f
        ].min
        image.resize(scale)
      else
        scale_x = target_width.to_f / image.width.to_f
        scale_y = target_height.to_f / image.height.to_f
        image.resize(scale_x, vscale: scale_y)
      end
    end

    def apply_rotation(image, degrees)
      normalized = degrees.to_f % 360.0
      return image if normalized.zero?

      right_angle = [ 0, 90, 180, 270 ].find { |angle| (normalized - angle).abs < 0.0001 }
      return image.rotate(right_angle.to_i) if right_angle && !right_angle.zero?

      background = Array.new([ image.bands, 1 ].max, 0)
      image.similarity(angle: normalized, background: background)
    end

    def write_output_image!(image, path, output)
      format = output[:format].presence&.downcase || source_file_extension.delete_prefix(".").downcase
      options = {}
      quality = output[:quality]

      if quality.present? && %w[jpg jpeg webp heif avif tiff tif].include?(format)
        options[:Q] = quality.to_i.clamp(1, 100)
      end

      image.write_to_file(path, **options)
    end

    def persist_derivative_asset!(output_file:, source_dimensions:, result_dimensions:, operations:, output:)
      file_extension = output_extension(output[:format] || source_file_extension)
      file_basename = File.basename(source_asset.filename.to_s, ".*")
      derivative_filename = "#{file_basename}_edit_#{Time.current.utc.strftime('%Y%m%d%H%M%S')}#{file_extension}"
      derivative_name = params[:name].presence || "#{source_asset.name} (Edited)"

      derivative_asset = Dam::Asset.new(
        name: derivative_name,
        description: params[:description].presence || source_asset.description,
        tenant: source_asset.tenant,
        user: actor,
        visibility_level: source_asset.visibility_level,
        parent_asset: source_asset,
        lineage_id: source_asset.lineage_identifier,
        derivative_kind: params[:derivative_kind].presence || "edit",
        original_path: source_asset.original_path,
        edit_recipe: {
          source_asset_id: source_asset.id,
          source_dimensions: source_dimensions,
          result_dimensions: result_dimensions,
          operations: operations,
          output: output,
          editor: "dam-image-editor-v1"
        }
      )

      output_file.rewind
      inferred_content_type = Marcel::MimeType.for(Pathname.new(output_file.path), name: derivative_filename)
      fallback_content_type = "image/#{output_extension(output[:format] || source_file_extension).delete_prefix('.')}"
      derivative_asset.file.attach(
        io: output_file,
        filename: derivative_filename,
        content_type: inferred_content_type || fallback_content_type
      )

      derivative_asset.save!

      copy_tags = params.key?(:copy_tags) ? ActiveModel::Type::Boolean.new.cast(params[:copy_tags]) : true
      if copy_tags && source_asset.tags.exists?
        source_asset.tags.find_each do |tag|
          derivative_asset.asset_tags.find_or_create_by!(tag: tag, tenant: derivative_asset.tenant)
        end
      end

      derivative_asset
    end

    def integer_param(value, default:)
      Integer(value)
    rescue ArgumentError, TypeError
      default
    end

    def float_param(value, default:)
      Float(value)
    rescue ArgumentError, TypeError
      default
    end

    def source_file_extension
      File.extname(source_asset.filename.to_s).downcase
    end

    def output_extension(format)
      case format
      when "jpg", "jpeg"
        ".jpg"
      when "png"
        ".png"
      when "webp"
        ".webp"
      else
        source_file_extension.presence || ".jpg"
      end
    end
  end
end
