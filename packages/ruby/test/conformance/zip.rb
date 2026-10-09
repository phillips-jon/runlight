# frozen_string_literal: true

require "zlib"

module Conformance
  # ZIP reading as http-conformance.ts does it, and writing, for the fake that replays answers.
  module Zip
    module_function

    # The files in a ZIP, stored or deflated, by their local headers: [{"name" =>, "text" =>}, ...].
    def unzip(bytes)
      bytes = bytes.b
      files = []
      at = 0
      while at + 30 <= bytes.bytesize && bytes.unpack1("V", offset: at) == 0x04034b50
        method = bytes.unpack1("v", offset: at + 8)
        size = bytes.unpack1("V", offset: at + 18)
        name_length = bytes.unpack1("v", offset: at + 26)
        extra = bytes.unpack1("v", offset: at + 28)
        name = Text.utf8(bytes.byteslice(at + 30, name_length))
        start = at + 30 + name_length + extra
        data = bytes.byteslice(start, size).to_s
        if method == 8
          begin
            data = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)
          rescue Zlib::Error
            raise "The ZIP's #{name} does not inflate"
          end
        end
        files << { "name" => name, "text" => Text.utf8(data) }
        at = start + size
      end
      files
    end

    # A ZIP of these files, each deflated or stored as `deflate` says, with a central directory.
    def zip(files, deflate: true)
      local = String.new(encoding: Encoding::BINARY)
      central = String.new(encoding: Encoding::BINARY)
      files.each do |file|
        text = file["text"].b
        name = file["name"].b
        data = deflate ? raw_deflate(text) : text
        method = deflate ? 8 : 0
        crc = Zlib.crc32(text)
        offset = local.bytesize
        local << [0x04034b50, 20, 0x0800, method, 0, 0, crc, data.bytesize, text.bytesize, name.bytesize, 0]
                 .pack("VvvvvvVVVvv") << name << data
        central << [0x02014b50, 20, 20, 0x0800, method, 0, 0, crc, data.bytesize, text.bytesize, name.bytesize, 0, 0,
                    0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
      end
      local + central + [0x06054b50, 0, 0, files.length, files.length, central.bytesize, local.bytesize, 0]
                        .pack("VvvvvVVv")
    end

    def raw_deflate(text)
      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      out = deflater.deflate(text, Zlib::FINISH)
      deflater.close
      out
    end

    private_class_method :raw_deflate
  end

  # Bytes read as text, as TextDecoder reads them: a leading byte order mark dropped, and each ill-formed
  # sequence as U+FFFD.
  module Text
    module_function

    def utf8(bytes)
      bytes = bytes.b
      bytes = bytes.byteslice(3..) if bytes.start_with?("\xEF\xBB\xBF".b)
      Runlight::Js.scrub(bytes)
    end
  end
end
