// Package mmdb reads MaxMind DB files (the MMDB format that MaxMind's
// GeoLite2 and DB-IP's free databases use) with the standard library alone.
// It answers what the TypeScript server's mmdb-lib answers: the record for
// an address, maps with their keys in the file's order, or nil when the
// address is not in the database.
//
// A database opened from a file is read a page at a time as lookups need it,
// so a 130 MB city database costs each lookup a few kilobytes of reads.
//
// Format: https://maxmind.github.io/MaxMind-DB/
package mmdb

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/netip"
	"os"
	"sync"

	"runlight.sh/go/internal/js"
)

var metadataMarker = []byte("\xAB\xCD\xEFMaxMind.com")

const (
	// metadataMax: the metadata sits in the file's last 128 KiB.
	metadataMax = 131072
	page        = 4096
	// pagesKept is how many pages of a file are kept at once; a lookup reads a few dozen.
	pagesKept = 256
)

// Reader is an open database. It is safe for use by many goroutines at once.
type Reader struct {
	// Metadata is the database's metadata map.
	Metadata *js.Object

	src        io.ReaderAt
	size       int64
	closer     io.Closer
	nodeCount  int64
	recordSize int64
	nodeBytes  int64
	dataStart  int64
	ipVersion  int64

	mu        sync.Mutex
	pages     map[int64][]byte
	ipv4Start int64
	ipv4Found bool
}

// FromBytes opens a database held in memory.
func FromBytes(b []byte) (*Reader, error) {
	return open(bytes.NewReader(b), int64(len(b)), nil)
}

// Open opens a database file, read a page at a time as lookups need it.
func Open(file string) (*Reader, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, fmt.Errorf("could not read %s: %w", file, err)
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	r, err := open(f, st.Size(), f)
	if err != nil {
		f.Close()
		return nil, err
	}
	return r, nil
}

// Close closes the file a database was opened from.
func (r *Reader) Close() error {
	if r.closer != nil {
		return r.closer.Close()
	}
	return nil
}

func open(src io.ReaderAt, size int64, closer io.Closer) (*Reader, error) {
	r := &Reader{src: src, size: size, closer: closer, pages: map[int64][]byte{}}
	tailStart := max(0, size-metadataMax)
	tail := r.read(tailStart, size-tailStart)
	at := bytes.LastIndex(tail, metadataMarker)
	if at < 0 {
		return nil, errors.New("not a MaxMind DB file: no metadata")
	}
	start := tailStart + int64(at) + int64(len(metadataMarker))
	value, _, err := r.decode(start, start, 0)
	if err != nil {
		return nil, err
	}
	meta, ok := value.(*js.Object)
	if !ok || !meta.Has("node_count") || !meta.Has("record_size") || !meta.Has("ip_version") {
		return nil, errors.New("not a MaxMind DB file: bad metadata")
	}
	r.Metadata = meta
	r.nodeCount = int64(js.Num(meta.Value("node_count")))
	r.recordSize = int64(js.Num(meta.Value("record_size")))
	r.ipVersion = int64(js.Num(meta.Value("ip_version")))
	if r.recordSize != 24 && r.recordSize != 28 && r.recordSize != 32 {
		return nil, fmt.Errorf("unsupported record size %d", r.recordSize)
	}
	r.nodeBytes = r.recordSize / 4
	r.dataStart = r.nodeCount*r.nodeBytes + 16
	return r, nil
}

// read is length bytes from at, fewer at the end of the database.
func (r *Reader) read(at, length int64) []byte {
	end := min(at+length, r.size)
	if at >= end {
		return nil
	}
	if br, ok := r.src.(*bytes.Reader); ok {
		out := make([]byte, end-at)
		n, _ := br.ReadAt(out, at)
		return out[:n]
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]byte, 0, end-at)
	for at < end {
		number := at / page
		p, ok := r.pages[number]
		if !ok {
			if len(r.pages) >= pagesKept {
				r.pages = map[int64][]byte{}
			}
			p = make([]byte, page)
			n, _ := r.src.ReadAt(p, number*page)
			p = p[:n]
			r.pages[number] = p
		}
		offset := at - number*page
		if offset >= int64(len(p)) {
			break
		}
		piece := p[offset:min(int64(len(p)), offset+end-at)]
		out = append(out, piece...)
		at += int64(len(piece))
	}
	return out
}

var errPastEnd = errors.New("invalid MaxMind DB: read past the end")

func (r *Reader) byteAt(at int64) (byte, error) {
	b := r.read(at, 1)
	if len(b) == 0 {
		return 0, errPastEnd
	}
	return b[0], nil
}

// ErrNotIP is the error for text that is not an IP address.
var ErrNotIP = errors.New("not an IP address")

// Get is the record for an address, nil when the database has none.
func (r *Reader) Get(ip string) (any, error) {
	addr, err := netip.ParseAddr(ip)
	if err != nil || addr.Zone() != "" {
		return nil, fmt.Errorf("%w: %s", ErrNotIP, ip)
	}
	var packed []byte
	if addr.Is4() {
		b := addr.As4()
		packed = b[:]
	} else {
		if r.ipVersion == 4 {
			return nil, fmt.Errorf("an IPv6 address cannot be looked up in an IPv4-only database: %s", ip)
		}
		b := addr.As16()
		packed = b[:]
	}
	node := int64(0)
	if len(packed) == 4 && r.ipVersion != 4 {
		node, err = r.ipv4()
		if err != nil {
			return nil, err
		}
	}
	bits := len(packed) * 8
	for i := 0; i < bits && node < r.nodeCount; i++ {
		bit := (packed[i>>3] >> (7 - (i & 7))) & 1
		node, err = r.record(node, int64(bit))
		if err != nil {
			return nil, err
		}
	}
	// The node count itself means no record, and so does a tree that ends before the address does.
	if node <= r.nodeCount {
		return nil, nil
	}
	value, _, err := r.decode(r.dataStart+node-r.nodeCount-16, r.dataStart, 0)
	return value, err
}

// ipv4 is where IPv4 addresses live in an IPv6 tree, under ::/96: the node
// 96 left turns down.
func (r *Reader) ipv4() (int64, error) {
	r.mu.Lock()
	if r.ipv4Found {
		defer r.mu.Unlock()
		return r.ipv4Start, nil
	}
	r.mu.Unlock()
	node := int64(0)
	for i := 0; i < 96 && node < r.nodeCount; i++ {
		var err error
		if node, err = r.record(node, 0); err != nil {
			return 0, err
		}
	}
	r.mu.Lock()
	r.ipv4Start, r.ipv4Found = node, true
	r.mu.Unlock()
	return node, nil
}

func (r *Reader) record(node, right int64) (int64, error) {
	b := r.read(node*r.nodeBytes, r.nodeBytes)
	if int64(len(b)) < r.nodeBytes {
		return 0, errPastEnd
	}
	switch r.recordSize {
	case 24:
		at := right * 3
		return int64(b[at])<<16 | int64(b[at+1])<<8 | int64(b[at+2]), nil
	case 28:
		if right == 0 {
			return int64(b[3]&0xF0)<<20 | int64(b[0])<<16 | int64(b[1])<<8 | int64(b[2]), nil
		}
		return int64(b[3]&0x0F)<<24 | int64(b[4])<<16 | int64(b[5])<<8 | int64(b[6]), nil
	}
	return int64(binary.BigEndian.Uint32(b[right*4:])), nil
}

func unsigned(b []byte) int64 {
	n := int64(0)
	for _, c := range b {
		n = n<<8 | int64(c)
	}
	return n
}

// decode is the value at at, and the offset just past it; pointers are
// offsets from base.
func (r *Reader) decode(at, base int64, depth int) (any, int64, error) {
	if depth > 512 {
		return nil, 0, errors.New("invalid MaxMind DB: nested too deeply")
	}
	control, err := r.byteAt(at)
	if err != nil {
		return nil, 0, err
	}
	at++
	typ := int64(control >> 5)
	if typ == 1 {
		// A pointer: up to four more bytes of offset, then the value found there.
		ss := int64(control>>3) & 3
		vvv := int64(control & 7)
		b := r.read(at, ss+1)
		if int64(len(b)) < ss+1 {
			return nil, 0, errPastEnd
		}
		var pointer int64
		switch ss {
		case 0:
			pointer = vvv<<8 | int64(b[0])
		case 1:
			pointer = (vvv<<16 | int64(b[0])<<8 | int64(b[1])) + 2048
		case 2:
			pointer = (vvv<<24 | int64(b[0])<<16 | int64(b[1])<<8 | int64(b[2])) + 526336
		default:
			pointer = unsigned(b[:4])
		}
		value, _, err := r.decode(base+pointer, base, depth+1)
		return value, at + ss + 1, err
	}
	if typ == 0 {
		ext, err := r.byteAt(at)
		if err != nil {
			return nil, 0, err
		}
		typ = 7 + int64(ext)
		at++
	}
	size := int64(control & 0x1F)
	if size >= 29 {
		extra := size - 28
		n := unsigned(r.read(at, extra))
		size = map[int64]int64{29: 29, 30: 285, 31: 65821}[size] + n
		at += extra
	}
	switch typ {
	case 2: // UTF-8 string
		return string(r.read(at, size)), at + size, nil
	case 3: // double
		b := r.read(at, 8)
		if len(b) < 8 {
			return nil, 0, errPastEnd
		}
		return math.Float64frombits(binary.BigEndian.Uint64(b)), at + 8, nil
	case 4: // bytes
		return string(r.read(at, size)), at + size, nil
	case 5, 6: // uint16, uint32
		return float64(unsigned(r.read(at, size))), at + size, nil
	case 7: // map
		m := &js.Object{}
		for i := int64(0); i < size; i++ {
			key, next, err := r.decode(at, base, depth+1)
			if err != nil {
				return nil, 0, err
			}
			value, next2, err := r.decode(next, base, depth+1)
			if err != nil {
				return nil, 0, err
			}
			m.Set(js.String(key), value)
			at = next2
		}
		return m, at, nil
	case 8: // int32
		n := unsigned(r.read(at, size))
		if size == 4 && n >= 0x80000000 {
			n -= 0x100000000
		}
		return float64(n), at + size, nil
	case 9, 10: // uint64, uint128
		return bigValue(r.read(at, size)), at + size, nil
	case 11: // array
		list := make([]any, 0, min(size, 1024))
		for i := int64(0); i < size; i++ {
			value, next, err := r.decode(at, base, depth+1)
			if err != nil {
				return nil, 0, err
			}
			list = append(list, value)
			at = next
		}
		return list, at, nil
	case 14: // boolean, its value in the size
		return size != 0, at, nil
	case 15: // float
		b := r.read(at, 4)
		if len(b) < 4 {
			return nil, 0, errPastEnd
		}
		return float64(math.Float32frombits(binary.BigEndian.Uint32(b))), at + 4, nil
	}
	return nil, 0, fmt.Errorf("invalid MaxMind DB: unknown data type %d", typ)
}

// bigValue is an unsigned integer of up to 16 bytes: a number when it is
// below 2^53, else its decimal digits.
func bigValue(b []byte) any {
	n := new(big.Int).SetBytes(b)
	if n.BitLen() <= 53 {
		return float64(n.Int64())
	}
	return n.String()
}
