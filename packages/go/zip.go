package runlight

import (
	"encoding/binary"
	"hash/crc32"
	"regexp"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
)

// ZipFile is one text file in a ZIP.
type ZipFile struct {
	Name string
	Text string
}

// Zip is a ZIP file of text files, stored without compression, with every
// entry dated now (epoch milliseconds, UTC).
func Zip(files []ZipFile, now int64) []byte {
	t := time.UnixMilli(now).UTC()
	dosTime := uint16(t.Hour()<<11 | t.Minute()<<5 | t.Second()/2)
	dosDay := uint16((t.Year()-1980)<<9 | int(t.Month())<<5 | t.Day())
	var local, central []byte
	le16 := binary.LittleEndian.AppendUint16
	le32 := binary.LittleEndian.AppendUint32
	offset := uint32(0)
	for _, f := range files {
		name := []byte(js.WellFormed(f.Name))
		data := []byte(js.WellFormed(f.Text))
		crc := crc32.ChecksumIEEE(data)
		local = le32(local, 0x04034b50)
		local = le16(local, 20)
		local = le16(local, 0x0800) // names are UTF-8
		local = le16(local, 0)      // stored
		local = le16(local, dosTime)
		local = le16(local, dosDay)
		local = le32(local, crc)
		local = le32(local, uint32(len(data)))
		local = le32(local, uint32(len(data)))
		local = le16(local, uint16(len(name)))
		local = le16(local, 0)
		local = append(local, name...)
		local = append(local, data...)

		central = le32(central, 0x02014b50)
		central = le16(central, 20)
		central = le16(central, 20)
		central = le16(central, 0x0800)
		central = le16(central, 0)
		central = le16(central, dosTime)
		central = le16(central, dosDay)
		central = le32(central, crc)
		central = le32(central, uint32(len(data)))
		central = le32(central, uint32(len(data)))
		central = le16(central, uint16(len(name)))
		central = append(central, make([]byte, 12)...)
		central = le32(central, offset)
		central = append(central, name...)
		offset += uint32(30 + len(name) + len(data))
	}
	end := le32(nil, 0x06054b50)
	end = append(end, 0, 0, 0, 0)
	end = le16(end, uint16(len(files)))
	end = le16(end, uint16(len(files)))
	end = le32(end, uint32(len(central)))
	end = le32(end, offset)
	end = append(end, 0, 0)
	out := append(local, central...)
	return append(out, end...)
}

var (
	formulaStart = regexp.MustCompile(`^[=+\-@\t\r]`)
	plainNumber  = regexp.MustCompile(`^-?\d+(\.\d+)?$`)
	needsQuotes  = regexp.MustCompile(`[",\n\r]`)
)

// CsvRow is one CSV row, quoting what needs it; a leading =, +, -, or @ is
// escaped so a spreadsheet will not run it. A nil value is an empty cell,
// and anything else is written as String() writes it.
func CsvRow(values []any) string {
	cells := make([]string, len(values))
	for i, v := range values {
		s := ""
		if v != nil {
			if _, undefined := v.(js.Undefined); !undefined {
				s = js.String(v)
			}
		}
		if formulaStart.MatchString(s) && !plainNumber.MatchString(s) {
			s = "'" + s
		}
		if needsQuotes.MatchString(s) {
			s = `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
		}
		cells[i] = s
	}
	return strings.Join(cells, ",")
}

// Csv is a CSV file: a header row, then the rows, each line ending in CRLF.
func Csv(header []string, rows [][]any) string {
	h := make([]any, len(header))
	for i, s := range header {
		h[i] = s
	}
	lines := []string{CsvRow(h)}
	for _, r := range rows {
		lines = append(lines, CsvRow(r))
	}
	return strings.Join(lines, "\r\n") + "\r\n"
}
