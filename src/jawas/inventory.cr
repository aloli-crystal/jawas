require "json"

module Jawas
  # Inventaire des sauvegardes présentes dans le stockage (`jawas list`).
  module Inventory
    record Entry, source : String, period : String, database : String, path : String,
      time : Time, size : Int64, checksum : Bool do
      include JSON::Serializable

      def encrypted : Bool
        path.ends_with?(Encryptor::EXTENSION)
      end
    end

    def self.scan(layout : Layout, sources : Array(String)) : Array(Entry)
      entries = [] of Entry
      sources.each do |source|
        Period.values.each do |period|
          base = layout.period_dir(source, period)
          next unless Dir.exists?(base)
          Dir.children(base).sort.each do |db|
            dir = File.join(base, db)
            next unless Dir.exists?(dir)
            Dir.children(dir).each do |name|
              path = File.join(dir, name)
              next unless Layout.backup_file?(path)
              entries << Entry.new(source, period.dirname, db, path, Layout.backup_time(path),
                File.size(path).to_i64, File.exists?("#{path}.sha256"))
            end
          end
        end
      end
      entries.sort_by! { |e| {e.source, e.period, e.database, e.time} }
    end
  end

  # Taille lisible (1 Kio = 1024 octets).
  def self.human_size(bytes : Int64) : String
    units = %w[o Kio Mio Gio Tio]
    value = bytes.to_f
    unit = 0
    while value >= 1024 && unit < units.size - 1
      value /= 1024
      unit += 1
    end
    unit.zero? ? "#{bytes} o" : "#{value.round(1)} #{units[unit]}"
  end
end
