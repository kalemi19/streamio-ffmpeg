require 'time'
require 'multi_json'
require 'uri'
require 'addressable/uri'
require 'net/http'
require 'dentaku'

# padding is to prevent width/height from not being divisible by 2
PADDING = 'pad=ceil(iw/2)*2:ceil(ih/2)*2'.freeze

# DAR conversion and preventing width/height from not being divisible by 2
DAR = 'scale=trunc(ceil((ih*dar)/2)*2):ceil(ih/2)*2, setsar=1/1'.freeze
BT709_DAR = "#{DAR}, setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709".freeze

# command to convert HDR to SDR
HDR_TO_SDR = 'zscale=t=linear:npl=170, format=gbrpf32le, zscale=p=bt709, tonemap=tonemap=hable:desat=0, zscale=t=bt709:m=bt709:r=tv, format=yuv420p'.freeze
BT709_HDR_TO_SDR = 'colorspace=all=bt709:iall=bt2020'.freeze

module FFMPEG
  class Movie
    attr_reader :path, :duration, :time, :bitrate, :rotation, :creation_time
    attr_reader :video_stream, :video_codec, :video_bitrate, :colorspace, :width, :height, :sar, :dar, :frame_rate
    attr_reader :audio_streams, :audio_stream, :audio_codec, :audio_bitrate, :audio_sample_rate, :audio_channels, :audio_tags
    attr_reader :container
    attr_reader :metadata, :format_tags

    UNSUPPORTED_CODEC_PATTERN = /^Unsupported codec with id (\d+) for input stream (\d+)$/

    def initialize(path, retrying = false)
      @path = Addressable::URI.escape(path)

      if remote?
        @head = head
        unless @head.is_a?(Net::HTTPSuccess)
          raise Errno::ENOENT, "the URL '#{path}' does not exist or is not available (response code: #{@head.code})"
        end
      else
        raise Errno::ENOENT, "the file '#{path}' does not exist" unless File.exist?(path)
      end

      @path = path

      # ffmpeg will output to stderr
      command = [FFMPEG.ffprobe_binary, '-i', path, *%w(-print_format json -show_format -show_streams -show_error)]
      std_output = ''
      std_error = ''

      std_output, std_error, status = Open3.capture3(*command)

      fix_encoding(std_output)
      fix_encoding(std_error)

      begin
        @metadata = MultiJson.load(std_output, symbolize_keys: true)
      rescue MultiJson::ParseError
        raise "Could not parse output from FFProbe:\n#{ std_output }"
      end

      if @metadata.key?(:error)
        return initialize(path, true) unless retrying
        @duration = 0
      else
        video_streams = @metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'video' }
        audio_streams = @metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'audio' }

        @container = @metadata[:format][:format_name]

        @duration = @metadata[:format][:duration].to_f

        @time = @metadata[:format][:start_time].to_f

        @format_tags = @metadata[:format][:tags]

        @creation_time = if @format_tags and @format_tags.key?(:creation_time)
                           begin
                             Time.parse(@format_tags[:creation_time])
                           rescue ArgumentError
                             nil
                           end
                         else
                           nil
                         end

        @bitrate = @metadata[:format][:bit_rate].to_i

        # TODO: Handle multiple video codecs (is that possible?)
        video_stream = video_streams.first
        unless video_stream.nil?
          @video_codec = video_stream[:codec_name]
          @colorspace = video_stream[:pix_fmt]
          @sar = video_stream[:sample_aspect_ratio]
          @dar = video_stream[:display_aspect_ratio]
          @height = video_stream[:height]
          @width = if @dar
           calculator = Dentaku::Calculator.new
           ratio = calculator.evaluate(@dar.sub(':', '/')).to_f
           @height * ratio
         else
           video_stream[:width]
         end
          @video_bitrate = video_stream[:bit_rate].to_i

          @frame_rate = unless video_stream[:avg_frame_rate] == '0/0'
                          Rational(video_stream[:avg_frame_rate])
                        else
                          nil
                        end

          @video_stream = "#{video_stream[:codec_name]} (#{video_stream[:profile]}) (#{video_stream[:codec_tag_string]} / #{video_stream[:codec_tag]}), #{colorspace}, #{resolution} [SAR #{sar} DAR #{dar}]"

          @rotation = if video_stream.key?(:tags) and video_stream[:tags].key?(:rotate)
                        video_stream[:tags][:rotate].to_i
                      elsif video_stream.key?(:side_data_list) and video_stream[:side_data_list]&.first.key?(:rotation)
                        video_stream[:side_data_list].first[:rotation].to_i
                      else
                        nil
                      end
        end

        @audio_streams = audio_streams.map do |stream|
          {
            :index => stream[:index],
            :channels => stream[:channels].to_i,
            :codec_name => stream[:codec_name],
            :sample_rate => stream[:sample_rate].to_i,
            :bitrate => stream[:bit_rate].to_i,
            :channel_layout => stream[:channel_layout],
            :tags => stream[:streams],
            :overview => "#{stream[:codec_name]} (#{stream[:codec_tag_string]} / #{stream[:codec_tag]}), #{stream[:sample_rate]} Hz, #{stream[:channel_layout]}, #{stream[:sample_fmt]}, #{stream[:bit_rate]} bit/s"
          }
        end

        audio_stream = @audio_streams.first
        unless audio_stream.nil?
          @audio_channels = audio_stream[:channels]
          @audio_codec = audio_stream[:codec_name]
          @audio_sample_rate = audio_stream[:sample_rate]
          @audio_bitrate = audio_stream[:bitrate]
          @audio_channel_layout = audio_stream[:channel_layout]
          @audio_tags = audio_stream[:audio_tags]
          @audio_stream = audio_stream[:overview]
        end

      end

      unsupported_stream_ids = unsupported_streams(std_error)
      nil_or_unsupported = ->(stream) { stream.nil? || unsupported_stream_ids.include?(stream[:index]) }

      @invalid = true if nil_or_unsupported.(video_stream) && nil_or_unsupported.(audio_stream)
      @invalid = true if @metadata.key?(:error)
      @invalid = true if std_error.include?("could not find codec parameters")
    end

    def unsupported_streams(std_error)
      [].tap do |stream_indices|
        std_error.each_line do |line|
          match = line.match(UNSUPPORTED_CODEC_PATTERN)
          stream_indices << match[2].to_i if match
        end
      end
    end

    def valid?
      not @invalid
    end

    def remote?
      @path =~ URI::regexp(%w(http https))
    end

    def local?
      not remote?
    end

    def width
      rotation.nil? || rotation.abs == 180 ? @width : @height;
    end

    def height
      rotation.nil? || rotation.abs == 180 ? @height : @width;
    end

    def resolution
      unless width.nil? or height.nil?
        "#{width}x#{height}"
      end
    end

    def calculated_aspect_ratio
      aspect_from_dar || aspect_from_dimensions
    end

    def calculated_pixel_aspect_ratio
      aspect_from_sar || 1
    end

    def size
      if local?
        File.size(@path)
      else
        @head.content_length
      end
    end

    def audio_channel_layout
      # TODO Whenever support for ffmpeg/ffprobe 1.2.1 is dropped this is no longer needed
      @audio_channel_layout || case(audio_channels)
                                 when 1
                                   'stereo'
                                 when 2
                                   'stereo'
                                 when 6
                                   '5.1'
                                 else
                                   'unknown'
                               end
    end

    def transcode(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options, transcoder_options).run &block
    end

    def screenshot(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options.merge(screenshot: true), transcoder_options).run &block
    end

    protected
    def aspect_from_dar
      calculate_aspect(dar)
    end

    def aspect_from_sar
      calculate_aspect(sar)
    end

    def calculate_aspect(ratio)
      return nil unless ratio
      w, h = ratio.split(':')
      return nil if w == '0' || h == '0'
      @rotation.nil? || (@rotation.abs == 180) ? (w.to_f / h.to_f) : (h.to_f / w.to_f)
    end

    def aspect_from_dimensions
      aspect = width.to_f / height.to_f
      aspect.nan? ? nil : aspect
    end

    def fix_encoding(output)
      output[/test/] # Running a regexp on the string throws error if it's not UTF-8
    rescue ArgumentError
      output.force_encoding("ISO-8859-1")
    end

    def head(location=@path, limit=FFMPEG.max_http_redirect_attempts)
      url = URI(location)
      return unless url.path

      request = Net::HTTP::Get.new(url)
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.port == 443
      response = http.request(request)

      case response
        when Net::HTTPRedirection then
          raise FFMPEG::HTTPTooManyRequests if limit == 0
          new_uri = url + URI(response['Location'])

          head(new_uri, limit - 1)
        else
          response
      end
    rescue SocketError, Errno::ECONNREFUSED => e
      nil
    end
  end
end
