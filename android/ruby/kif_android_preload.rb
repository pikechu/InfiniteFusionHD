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

  # HTTPS is supplied by Android's verified Java TLS stack through the pinned
  # JNI bridge. The multiplayer source loader installs its JSON adapter later.
  if ENV["KIF_ANDROID_NETWORK"] == "1"
    begin
      native_dir = ENV["KIF_NATIVE_LIB_DIR"]
      raise LoadError, "Native library directory is unavailable" unless native_dir && native_dir.start_with?("/")
      require File.join(native_dir, "libkif_android_bridge.so")
    rescue LoadError, StandardError => error
      System.puts("KIF verified network bridge unavailable (#{error.class})") if System.respond_to?(:puts)
    end
  end
end
