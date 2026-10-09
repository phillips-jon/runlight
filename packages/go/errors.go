package runlight

import (
	"errors"

	"runlight.sh/go/internal/js"
)

// CodedError is a refusal with a code and params, so the dashboard can say
// it in its own words. The error kinds below each embed one.
type CodedError struct {
	Message string
	Code    string
	// Params fill the placeholders of the code's message, in order.
	Params *js.Object
}

func (e *CodedError) Error() string { return e.Message }

// coded is the refusal itself, for code that reads any kind of coded error.
func (e *CodedError) coded() *CodedError { return e }

// codedOf is the CodedError err is or wraps, or nil.
func codedOf(err error) *CodedError {
	var c interface{ coded() *CodedError }
	if errors.As(err, &c) {
		return c.coded()
	}
	return nil
}

func coded(message, code string, params ...string) CodedError {
	return CodedError{Message: message, Code: code, Params: js.NewObject(stringsToAny(params)...)}
}

func stringsToAny(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

// GoalError is why a goal was refused.
type GoalError struct{ CodedError }

// FunnelError is why a funnel was refused.
type FunnelError struct{ CodedError }

// LinkError is a link that cannot be made.
type LinkError struct{ CodedError }

func goalError(message, code string, params ...string) error {
	return &GoalError{coded(message, code, params...)}
}

func funnelError(message, code string, params ...string) error {
	return &FunnelError{coded(message, code, params...)}
}

func linkError(message, code string, params ...string) error {
	return &LinkError{coded(message, code, params...)}
}

// RangeError is JavaScript's RangeError: a value out of what is allowed,
// such as an unknown link.
type RangeError struct{ Message string }

func (e *RangeError) Error() string { return e.Message }

// rangeLike is an error that is a RangeError in the TypeScript SDK: a
// RangeError itself, or a SettingsError or ConnectError, which extend it.
type rangeLike interface{ isRangeError() }

func (*RangeError) isRangeError() {}

// isRangeError reports whether err is, or wraps, an error the TypeScript
// SDK throws as a RangeError.
func isRangeError(err error) bool {
	var r rangeLike
	return errors.As(err, &r)
}

func rangeError(message string) error { return &RangeError{message} }
