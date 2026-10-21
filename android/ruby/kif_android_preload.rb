# Loaded by Android mkxp.json before Data/Scripts.rxdata. Keep all files writable
# by the runtime inside the app's private storage; never use desktop save paths.
if defined?(System) && System.respond_to?(:is_android?) && System.is_android?
  # Essentials/KIF still uses these aliases, removed by Ruby 3.2. Preserve the
  # native implementation when a runtime already supplies either compatibility
  # method, and never change the Windows runtime.
  class << File
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
  class << Dir
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end

  module KIF
    module Platform
      class << self
        attr_reader :save_root

        def initialize_android_storage
          supplied_path = ENV["KIF_SAVE_DIR"]
          if supplied_path.nil? || supplied_path.empty?
            raise "KIF_SAVE_DIR must name the Android app's private saves directory"
          end
          normalized_path = supplied_path.tr("\\", "/")
          unless normalized_path.start_with?("/") || normalized_path =~ /\A[A-Za-z]:\//
            raise "KIF_SAVE_DIR must be an absolute path"
          end
          directory = File.expand_path(normalized_path)
          Dir.mkdir(directory) unless File.directory?(directory)
          # Existing keybinding callers concatenate the filename directly.
          @save_root = directory.sub(%r{/+\z}, "") + "/"
        end
      end
    end
  end

  KIF::Platform.initialize_android_storage

  class << System
    def data_directory
      KIF::Platform.save_root
    end
  end

  if defined?(Bitmap)
    module KIF
      module AndroidBitmapPathInitialization
        def initialize(*args, &block)
          if args[0].is_a?(String) && KIF::Platform.respond_to?(:read_bitmap_path)
            args[0] = KIF::Platform.read_bitmap_path(args[0])
          end
          super(*args, &block)
        end
      end
    end
    Bitmap.prepend(KIF::AndroidBitmapPathInitialization) unless Bitmap.ancestors.include?(KIF::AndroidBitmapPathInitialization)
  end

  # Input and verified networking are independent capabilities of the same helper.
  # A missing helper must not restore the runtime's unverified HTTP client.
  KIF::Platform.instance_variable_set(:@android_native_bridge_loaded, false)
  KIF::Platform.instance_variable_set(:@android_network_bridge_loaded, false)
  KIF::Platform.instance_variable_set(:@android_input_bridge_loaded, false)
  if ENV["KIF_ANDROID_NETWORK"] == "1" || ENV["KIF_ANDROID_INPUT"] == "1"
    begin
      native_dir = ENV["KIF_NATIVE_LIB_DIR"]
      unless native_dir.is_a?(String) && (native_dir.start_with?("/") || native_dir.match?(/\A[A-Za-z]:[\\\/]/))
        raise LoadError, "Native library directory unavailable"
      end
      bridge_library = File.join(native_dir, "libkif_android_bridge.so")
      raise LoadError, "Native Android bridge unavailable" unless File.file?(bridge_library)
      require bridge_library
      raise LoadError, "Native Android bridge module unavailable" unless defined?(KIFAndroidBridge)
      KIF::Platform.instance_variable_set(:@android_native_bridge_loaded, true)
      KIF::Platform.instance_variable_set(:@android_network_bridge_loaded,
        ENV["KIF_ANDROID_NETWORK"] == "1" && KIFAndroidBridge.respond_to?(:request))
      KIF::Platform.instance_variable_set(:@android_input_bridge_loaded,
        ENV["KIF_ANDROID_INPUT"] == "1" && KIFAndroidBridge.respond_to?(:input_poll))
    rescue LoadError, StandardError => error
      System.puts("KIF Android native bridge unavailable (#{error.class}); continuing offline with native input") if System.respond_to?(:puts)
    end
  end
end
