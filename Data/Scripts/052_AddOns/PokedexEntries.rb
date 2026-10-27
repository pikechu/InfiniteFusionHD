# Custom dex records belong to a sprite and author, not just a species. Keep
# KIF's records in their original order and append only distinct valid text.
module KIF
  module PokedexEntries
    MAX_BYTES = 32 * 1024 * 1024
    MAX_ENTRIES = 100_000

    def self.entries_for(sprite)
      path = Settings::CUSTOM_DEX_ENTRIES_PATH
      stamp = File.file?(path) ? [File.size(path), File.mtime(path).to_f, File.ctime(path).to_f] : nil
      if @display_stamp != stamp || !@display_index
        @display_index = {}
        records = stamp ? parse(File.binread(path)) : []
        records.each do |row|
          next unless valid?(row)
          (@display_index[row["sprite"]] ||= []) << row["entry"]
        end
        @display_stamp = stamp
      end
      @display_index[sprite]
    end

    def self.parse(text)
      raise ArgumentError, "Invalid custom dex size" unless text.is_a?(String) && text.bytesize <= MAX_BYTES
      text = text.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "Invalid custom dex encoding" unless text.valid_encoding?
      records = HTTPLite::JSON.parse(text.sub(/\A\uFEFF/, ""))
      raise ArgumentError, "Expected custom dex array" unless records.is_a?(Array) && records.length <= MAX_ENTRIES
      records.each do |record|
        next unless record.is_a?(Hash)
        # The native parser returns numeric author names (e.g. 9000) as Floats.
        author = record["author"]
        if author.is_a?(Float) && author.finite? && author == author.to_i
          record["author"] = author.to_i
        end
      end
      records
    end

    def self.valid?(record)
      record.is_a?(Hash) && record.keys.all? { |key| key.is_a?(String) } &&
        record["sprite"].is_a?(String) && record["sprite"].end_with?(".png") &&
        record["entry"].is_a?(String) &&
        (record["author"].is_a?(String) || record["author"].is_a?(Integer))
    end

    def self.merge(existing, incoming)
      raise ArgumentError, "Invalid existing custom dex" unless existing.is_a?(Array) && existing.all? { |record| valid?(record) }
      raise ArgumentError, "Expected incoming custom dex array" unless incoming.is_a?(Array)
      entries = existing.dup
      known = {}
      existing.each { |record| known[record] = true }
      added = skipped = 0
      incoming.each do |record|
        unless valid?(record)
          skipped += 1
          next
        end
        next if known[record]
        known[record] = true
        entries << record
        added += 1
      end
      raise ArgumentError, "Too many custom dex entries" if entries.length > MAX_ENTRIES
      { :entries => entries, :added => added, :skipped => skipped }
    end

    def self.write(path, records)
      body = HTTPLite::JSON.stringify(records)
      raise ArgumentError, "Invalid serialized custom dex" unless body.is_a?(String) && body.bytesize <= MAX_BYTES
      stamp = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000_000).to_i
      pending = File.join(File.dirname(path), ".#{File.basename(path)}.kif-dex-#{Process.pid}-#{Thread.current.object_id}-#{stamp}.pending")
      owned = false
      begin
        File.open(pending, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0600) do |file|
          owned = true
          raise IOError, "Short custom dex write" unless file.write(body) == body.bytesize
          file.flush
          file.fsync
        end
        # The staging file shares the destination's filesystem. On failure the
        # original stays intact; never delete it to work around rename errors.
        File.rename(pending, path)
      ensure
        begin
          File.delete(pending) if owned && File.file?(pending)
        rescue SystemCallError, IOError
          # Preserve the original write/rename error if cleanup also fails.
        end
      end
      path
    end
  end
end
