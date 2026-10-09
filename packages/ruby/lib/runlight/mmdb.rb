# frozen_string_literal: true

require "ipaddr"

module Runlight
  # A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and
  # DB-IP's free databases use), in plain Ruby so location needs no extension or
  # library. It answers what the TypeScript server's mmdb-lib answers: the
  # record for an address, maps as Hashes with String keys, or nil when the
  # address is not in the database.
  #
  # A database opened from a file is read a page at a time as lookups need it,
  # so a 130 MB city database costs each request a few hundred kilobytes of reads.
  #
  # Format: https://maxmind.github.io/MaxMind-DB/
  class Mmdb
    METADATA_MARKER = "\xAB\xCD\xEFMaxMind.com".b
    # The metadata sits in the file's last 128 KiB.
    METADATA_MAX = 131_072
    PAGE = 4096
    # Pages kept from a file at once; a lookup reads a few dozen.
    PAGES_KEPT = 256
    private_constant :METADATA_MARKER, :METADATA_MAX, :PAGE, :PAGES_KEPT

    attr_reader :metadata

    # bytes: the whole database, or "" with `handle`, an open file to read pages from instead.
    def initialize(bytes, handle = nil)
      @bytes = bytes.b
      @handle = handle
      @pages = {}
      @ipv4_start = nil
      @size = handle.nil? ? @bytes.bytesize : handle.size
      tail_start = [0, @size - METADATA_MAX].max
      at = read(tail_start, @size - tail_start).rindex(METADATA_MARKER)
      raise ArgumentError, "Not a MaxMind DB file: no metadata" if at.nil?

      start = tail_start + at + METADATA_MARKER.bytesize
      metadata, = decode(start, start)
      unless metadata.is_a?(Hash) && %w[node_count record_size ip_version].all? { |key| !metadata[key].nil? }
        raise ArgumentError, "Not a MaxMind DB file: bad metadata"
      end

      @metadata = metadata
      @node_count = metadata["node_count"].to_i
      @record_size = metadata["record_size"].to_i
      raise ArgumentError, "Unsupported record size #{@record_size}" unless [24, 28, 32].include?(@record_size)

      @node_bytes = @record_size / 4
      @data_start = (@node_count * @node_bytes) + 16
    end

    # A database read from its file as lookups need it.
    def self.open(file)
      handle = File.file?(file) ? File.open(file, "rb") : nil
      raise RuntimeError, "Could not read #{file}" if handle.nil?

      new("", handle)
    rescue SystemCallError
      raise RuntimeError, "Could not read #{file}"
    end

    # The record for an address, or nil. Raises ArgumentError for text that is not an IP address.
    def get(ip)
      packed = pack(ip)
      raise ArgumentError, "Not an IP address: #{ip}" if packed.nil?

      v6 = packed.bytesize == 16
      if v6 && @metadata["ip_version"].to_i == 4
        raise ArgumentError, "An IPv6 address cannot be looked up in an IPv4-only database: #{ip}"
      end

      node = v6 || @metadata["ip_version"].to_i == 4 ? 0 : ipv4_start
      bits = packed.bytesize * 8
      i = 0
      while i < bits && node < @node_count
        bit = (packed.getbyte(i >> 3) >> (7 - (i & 7))) & 1
        node = record(node, bit)
        i += 1
      end
      # The node count itself means no record, and so does a tree that ends before the address does.
      return nil if node <= @node_count

      value, = decode(@data_start + node - @node_count - 16, @data_start)
      value
    end

    private

    # An address as inet_pton packs it, or nil when it is not one.
    def pack(ip)
      return nil if ip.include?("/") || ip.include?("%")

      IPAddr.new(ip).hton
    rescue IPAddr::Error, ArgumentError
      nil
    end

    # `length` bytes from `at`, fewer at the end of the database.
    def read(at, length)
      return @bytes.byteslice(at, length) || "".b if @handle.nil?

      out = +"".b
      finish = [at + length, @size].min
      while at < finish
        number = at / PAGE
        unless @pages.key?(number)
          @pages = {} if @pages.size >= PAGES_KEPT
          @handle.seek(number * PAGE)
          @pages[number] = @handle.read(PAGE) || "".b
        end
        offset = at - (number * PAGE)
        piece = @pages[number].byteslice(offset, finish - at) || "".b
        break if piece.empty?

        out << piece
        at += piece.bytesize
      end
      out
    end

    def byte(at)
      byte = @handle.nil? ? @bytes.getbyte(at) : read(at, 1).getbyte(0)
      raise RuntimeError, "Invalid MaxMind DB: read past the end" if byte.nil?

      byte
    end

    # IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down.
    def ipv4_start
      if @ipv4_start.nil?
        node = 0
        i = 0
        while i < 96 && node < @node_count
          node = record(node, 0)
          i += 1
        end
        @ipv4_start = node
      end
      @ipv4_start
    end

    def record(node, right)
      b = read(node * @node_bytes, @node_bytes)
      raise RuntimeError, "Invalid MaxMind DB: read past the end" if b.bytesize < @node_bytes

      case @record_size
      when 24
        at = right * 3
        (b.getbyte(at) << 16) | (b.getbyte(at + 1) << 8) | b.getbyte(at + 2)
      when 28
        if right.zero?
          ((b.getbyte(3) & 0xF0) << 20) | (b.getbyte(0) << 16) | (b.getbyte(1) << 8) | b.getbyte(2)
        else
          ((b.getbyte(3) & 0x0F) << 24) | (b.getbyte(4) << 16) | (b.getbyte(5) << 8) | b.getbyte(6)
        end
      else
        b.byteslice(right * 4, 4).unpack1("N")
      end
    end

    # Decodes the value at `at`; pointers are offsets from `base`. Gives the value and the offset just past it.
    def decode(at, base)
      control = byte(at)
      at += 1
      type = control >> 5
      if type == 1
        # A pointer: up to four more bytes of offset, then the value found there.
        ss = (control >> 3) & 3
        vvv = control & 7
        pointer = case ss
                  when 0 then (vvv << 8) | byte(at)
                  when 1 then ((vvv << 16) | (byte(at) << 8) | byte(at + 1)) + 2048
                  when 2 then ((vvv << 24) | (byte(at) << 16) | (byte(at + 1) << 8) | byte(at + 2)) + 526_336
                  else unsigned(read(at, 4))
                  end
        value, = decode(base + pointer, base)
        return [value, at + ss + 1]
      end
      if type.zero?
        type = 7 + byte(at)
        at += 1
      end
      size = control & 0x1F
      if size >= 29
        extra = size - 28
        n = 0
        extra.times { |i| n = (n << 8) | byte(at + i) }
        size = { 29 => 29, 30 => 285, 31 => 65_821 }[size] + n
        at += extra
      end
      case type
      when 2 # UTF-8 string
        [Js.scrub(read(at, size)), at + size]
      when 3 # double
        [read(at, 8).unpack1("G"), at + 8]
      when 4 # bytes
        [read(at, size), at + size]
      when 5, 6 # uint16, uint32
        [unsigned(read(at, size)), at + size]
      when 7 # map
        map = {}
        size.times do
          key, at = decode(at, base)
          value, at = decode(at, base)
          map[key.to_s] = value
        end
        [map, at]
      when 8 # int32
        n = unsigned(read(at, size))
        n -= 0x100000000 if size == 4 && n >= 0x80000000
        [n, at + size]
      when 9, 10 # uint64, uint128
        [big(read(at, size)), at + size]
      when 11 # array
        list = []
        size.times do
          value, at = decode(at, base)
          list << value
        end
        [list, at]
      when 14 # boolean, its value in the size
        [size != 0, at]
      when 15 # float
        [read(at, 4).unpack1("g"), at + 4]
      else
        raise RuntimeError, "Invalid MaxMind DB: unknown data type #{type}"
      end
    end

    def unsigned(bytes)
      bytes.each_byte.reduce(0) { |n, byte| (n << 8) | byte }
    end

    # An unsigned integer of up to 16 bytes: an Integer when it fits in 63 bits, as PHP's int does, else its
    # decimal digits.
    def big(bytes)
      n = unsigned(bytes)
      n < 2**63 ? n : n.to_s
    end
  end
end
