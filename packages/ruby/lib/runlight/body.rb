# frozen_string_literal: true

module Runlight
  # Capped reads of an answer's body. In Ruby the cap belongs on the request:
  # pass "maxBytes" to the fetcher, which stops reading past it and raises
  # Http::BodyTooLong, so an install or a page that answers without end never
  # fills memory. These check the same limit again on an answer already read,
  # for a fetcher that does not take the option, and decode the text as
  # TextDecoder does.
  module Body
    module_function

    # The body as text, up to max_bytes; past that, Http::BodyTooLong.
    def read_text_capped(response, max_bytes)
      # Number(header), as the TypeScript reads it: none is 0, and text that is not a number never counts.
      declared = Js.number(response.headers.get("content-length"))
      raise Http::BodyTooLong, "Body over #{max_bytes} bytes" if declared > max_bytes

      text = response.text
      raise Http::BodyTooLong, "Body over #{max_bytes} bytes" if text.bytesize > max_bytes

      utf8(text)
    end

    # The body as JSON, up to max_bytes, as read_text_capped reads it.
    def read_json_capped(response, max_bytes)
      Json.decode(read_text_capped(response, max_bytes))
    end

    # Text as TextDecoder gives it: U+FFFD where the bytes are not UTF-8, and no byte order mark.
    def utf8(bytes)
      bytes = bytes.b
      bytes = bytes.byteslice(3..) if bytes.start_with?("\xEF\xBB\xBF".b)
      Js.scrub(bytes)
    end
  end
end
