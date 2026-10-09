# frozen_string_literal: true

require "zlib"

module Runlight
  # A ZIP file of text files, stored without compression, and the CSV that
  # goes in it. Small and plain, so it needs no library.
  module Zip
    module_function

    # DOS date and time, as ZIP stores them: [time, day].
    def dos_time(ms)
      at = Time.at(ms.div(1000)).utc
      [
        ((at.hour << 11) | (at.min << 5) | (at.sec / 2)) & 0xFFFF,
        (((at.year - 1980) << 9) | (at.month << 5) | at.day) & 0xFFFF,
      ]
    end

    # The ZIP's bytes. Every entry carries the time `now` (epoch milliseconds, as the TypeScript's Date),
    # in UTC. files: an Array of Hashes {"name", "text"}.
    def zip(files, now = nil)
      time, day = dos_time(now || (Time.now.to_r * 1000).floor)
      parts = +"".b
      central = +"".b
      offset = 0
      files.each do |file|
        # TextEncoder writes UTF-8, with U+FFFD for anything that is not text.
        name = Js.scrub(file["name"]).b
        data = Js.scrub(file["text"]).b
        crc = Zlib.crc32(data)
        parts << [0x04034b50, 20, 0x0800, 0, time, day, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") << name << data
        central << [0x02014b50, 20, 20, 0x0800, 0, time, day, crc, data.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
        offset += 30 + name.bytesize + data.bytesize
      end
      ending = [0x06054b50, 0, 0, files.length, files.length, central.bytesize, offset, 0].pack("VvvvvVVv")
      parts + central + ending
    end

    # One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a spreadsheet will not run it.
    def csv_row(values)
      values.map do |v|
        s = v.nil? || v.equal?(UNDEFINED) ? "" : Js.string(v)
        s = "'#{s}" if s.match?(/\A[=+\-@\t\r]/) && !s.match?(/\A-?\d+(\.\d+)?\z/)
        s.match?(/[",\n\r]/) ? "\"#{s.gsub('"', '""')}\"" : s
      end.join(",")
    end

    # header: an Array of Strings; rows: an Array of Arrays of values.
    def csv(header, rows)
      "#{[csv_row(header), *rows.map { |row| csv_row(row) }].join("\r\n")}\r\n"
    end

    private_class_method :dos_time
  end
end
