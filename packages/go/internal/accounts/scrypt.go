package accounts

import (
	"crypto/pbkdf2"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"math/bits"
)

// Scrypt is scrypt (RFC 7914), since Go's standard library has none. It gives the same bytes as Node's
// crypto.scrypt, so a password hashed by either checks out in the other.
func Scrypt(password string, salt []byte, n, r, p, length int) ([]byte, error) {
	if n < 2 || n&(n-1) != 0 {
		return nil, errors.New("N must be a power of two greater than 1")
	}
	if r < 1 || p < 1 || length < 1 {
		return nil, errors.New("r, p, and the key length must be at least 1")
	}
	blockBytes := 128 * r
	b, err := pbkdf2.Key(sha256.New, password, salt, 1, blockBytes*p)
	if err != nil {
		return nil, err
	}
	x := make([]uint32, 32*r)
	v := make([]uint32, 32*r*n)
	y := make([]uint32, 32*r)
	for i := 0; i < p; i++ {
		roMix(b[i*blockBytes:(i+1)*blockBytes], x, y, v, n, r)
	}
	return pbkdf2.Key(sha256.New, password, b, 1, length)
}

// roMix is scryptROMix: it fills N blocks, then reads them back in an order that depends on each result.
func roMix(block []byte, x, y, v []uint32, n, r int) {
	words := 32 * r
	for i := range x {
		x[i] = binary.LittleEndian.Uint32(block[i*4:])
	}
	for i := 0; i < n; i++ {
		copy(v[i*words:], x)
		blockMix(x, y, r)
	}
	for i := 0; i < n; i++ {
		// Integerify: the first word of the last 64-byte part, which is the low bits of a little-endian number.
		j := int(x[(2*r-1)*16]) & (n - 1)
		for k, w := range v[j*words : (j+1)*words] {
			x[k] ^= w
		}
		blockMix(x, y, r)
	}
	for i, w := range x {
		binary.LittleEndian.PutUint32(block[i*4:], w)
	}
}

// blockMix is scryptBlockMix: 2r parts of 16 words, each mixed with the one before through Salsa20/8, the even
// results first and the odd ones after. y is scratch the size of b.
func blockMix(b, y []uint32, r int) {
	var t [16]uint32
	copy(t[:], b[(2*r-1)*16:])
	for k := 0; k < 2*r; k++ {
		for i := range t {
			t[i] ^= b[k*16+i]
		}
		salsa8(&t)
		at := (k / 2) * 16
		if k&1 == 1 {
			at += r * 16
		}
		copy(y[at:], t[:])
	}
	copy(b, y)
}

// salsa8 is the Salsa20/8 core, in place.
func salsa8(b *[16]uint32) {
	x := *b
	for round := 0; round < 4; round++ {
		// Columns.
		x[4] ^= bits.RotateLeft32(x[0]+x[12], 7)
		x[8] ^= bits.RotateLeft32(x[4]+x[0], 9)
		x[12] ^= bits.RotateLeft32(x[8]+x[4], 13)
		x[0] ^= bits.RotateLeft32(x[12]+x[8], 18)
		x[9] ^= bits.RotateLeft32(x[5]+x[1], 7)
		x[13] ^= bits.RotateLeft32(x[9]+x[5], 9)
		x[1] ^= bits.RotateLeft32(x[13]+x[9], 13)
		x[5] ^= bits.RotateLeft32(x[1]+x[13], 18)
		x[14] ^= bits.RotateLeft32(x[10]+x[6], 7)
		x[2] ^= bits.RotateLeft32(x[14]+x[10], 9)
		x[6] ^= bits.RotateLeft32(x[2]+x[14], 13)
		x[10] ^= bits.RotateLeft32(x[6]+x[2], 18)
		x[3] ^= bits.RotateLeft32(x[15]+x[11], 7)
		x[7] ^= bits.RotateLeft32(x[3]+x[15], 9)
		x[11] ^= bits.RotateLeft32(x[7]+x[3], 13)
		x[15] ^= bits.RotateLeft32(x[11]+x[7], 18)
		// Rows.
		x[1] ^= bits.RotateLeft32(x[0]+x[3], 7)
		x[2] ^= bits.RotateLeft32(x[1]+x[0], 9)
		x[3] ^= bits.RotateLeft32(x[2]+x[1], 13)
		x[0] ^= bits.RotateLeft32(x[3]+x[2], 18)
		x[6] ^= bits.RotateLeft32(x[5]+x[4], 7)
		x[7] ^= bits.RotateLeft32(x[6]+x[5], 9)
		x[4] ^= bits.RotateLeft32(x[7]+x[6], 13)
		x[5] ^= bits.RotateLeft32(x[4]+x[7], 18)
		x[11] ^= bits.RotateLeft32(x[10]+x[9], 7)
		x[8] ^= bits.RotateLeft32(x[11]+x[10], 9)
		x[9] ^= bits.RotateLeft32(x[8]+x[11], 13)
		x[10] ^= bits.RotateLeft32(x[9]+x[8], 18)
		x[12] ^= bits.RotateLeft32(x[15]+x[14], 7)
		x[13] ^= bits.RotateLeft32(x[12]+x[15], 9)
		x[14] ^= bits.RotateLeft32(x[13]+x[12], 13)
		x[15] ^= bits.RotateLeft32(x[14]+x[13], 18)
	}
	for i := range b {
		b[i] += x[i]
	}
}
