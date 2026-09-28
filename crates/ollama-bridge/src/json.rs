//! Minimal JSON parser and serializer (Rust stdlib only).
//!
//! Enough for the Ollama <-> OpenAI translation we need: we parse incoming
//! Ollama request bodies, rebuild OpenAI request bodies, and parse upstream
//! responses. Object member order is preserved (Vec of pairs) so we never
//! scramble what we pass through.

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    // -- construction helpers -------------------------------------------------

    pub fn obj(fields: Vec<(String, Json)>) -> Json {
        Json::Obj(fields)
    }

    pub fn arr(items: Vec<Json>) -> Json {
        Json::Arr(items)
    }

    pub fn str(s: impl Into<String>) -> Json {
        Json::Str(s.into())
    }

    pub fn num(n: f64) -> Json {
        Json::Num(n)
    }

    pub fn bool(b: bool) -> Json {
        Json::Bool(b)
    }

    pub fn null() -> Json {
        Json::Null
    }

    // -- accessors ------------------------------------------------------------

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(fields) => fields
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|n| n as i64)
    }

    pub fn as_arr(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_obj(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Obj(fields) => Some(fields),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    // -- parsing ---------------------------------------------------------------

    pub fn parse(input: &str) -> Result<Json, String> {
        let mut p = Parser {
            bytes: input.as_bytes(),
            pos: 0,
        };
        p.skip_ws();
        let value = p.parse_value()?;
        p.skip_ws();
        if p.pos != p.bytes.len() {
            return Err(format!("trailing data at byte {}", p.pos));
        }
        Ok(value)
    }

    // -- serialization ----------------------------------------------------------

    pub fn to_string(&self) -> String {
        let mut out = String::new();
        self.write_to(&mut out);
        out
    }

    fn write_to(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(true) => out.push_str("true"),
            Json::Bool(false) => out.push_str("false"),
            Json::Num(n) => {
                if n.fract() == 0.0 && n.abs() < 9_007_199_254_740_992.0 {
                    out.push_str(&format!("{}", *n as i64));
                } else {
                    out.push_str(&format!("{}", n));
                }
            }
            Json::Str(s) => {
                out.push('"');
                out.push_str(&Json::escape(s));
                out.push('"');
            }
            Json::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_to(out);
                }
                out.push(']');
            }
            Json::Obj(fields) => {
                out.push('{');
                for (i, (k, v)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push('"');
                    out.push_str(&Json::escape(k));
                    out.push_str("\":");
                    v.write_to(out);
                }
                out.push('}');
            }
        }
    }

    pub fn escape(s: &str) -> String {
        let mut out = String::with_capacity(s.len() + 16);
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{8}' => out.push_str("\\b"),
                '\u{c}' => out.push_str("\\f"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        match self.peek() {
            Some(b'{') => self.parse_obj(),
            Some(b'[') => self.parse_arr(),
            Some(b'"') => Ok(Json::Str(self.parse_string()?)),
            Some(b't') => self.parse_lit("true", Json::Bool(true)),
            Some(b'f') => self.parse_lit("false", Json::Bool(false)),
            Some(b'n') => self.parse_lit("null", Json::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.parse_num(),
            Some(c) => Err(format!("unexpected byte {} at offset {}", c, self.pos)),
            None => Err("unexpected end of input".into()),
        }
    }

    fn parse_lit(&mut self, lit: &str, value: Json) -> Result<Json, String> {
        if self.bytes[self.pos..].starts_with(lit.as_bytes()) {
            self.pos += lit.len();
            Ok(value)
        } else {
            Err(format!("invalid literal at offset {}", self.pos))
        }
    }

    fn parse_num(&mut self) -> Result<Json, String> {
        let start = self.pos;
        while self.pos < self.bytes.len() && {
            let c = self.bytes[self.pos];
            c.is_ascii_digit() || c == b'-' || c == b'+' || c == b'.' || c == b'e' || c == b'E'
        } {
            self.pos += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| "invalid number".to_string())?;
        text.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| format!("invalid number '{text}'"))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        // assumes current byte is '"'
        self.pos += 1;
        let mut out = String::new();
        loop {
            let c = *self
                .bytes
                .get(self.pos)
                .ok_or_else(|| "unterminated string".to_string())?;
            self.pos += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let esc = *self
                        .bytes
                        .get(self.pos)
                        .ok_or_else(|| "unterminated escape".to_string())?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let cp = self.parse_hex4()?;
                            // Handle UTF-16 surrogate pairs.
                            if (0xD800..0xDC00).contains(&cp) {
                                // Expect a low surrogate \uXXXX.
                                if self.bytes.get(self.pos) == Some(&b'\\')
                                    && self.bytes.get(self.pos + 1) == Some(&b'u')
                                {
                                    self.pos += 2;
                                    let lo = self.parse_hex4()?;
                                    if (0xDC00..0xE000).contains(&lo) {
                                        let c = 0x10000
                                            + ((cp - 0xD800) << 10)
                                            + (lo - 0xDC00);
                                        if let Some(ch) = char::from_u32(c) {
                                            out.push(ch);
                                        }
                                    } else {
                                        out.push('\u{FFFD}');
                                    }
                                } else {
                                    out.push('\u{FFFD}');
                                }
                            } else if let Some(ch) = char::from_u32(cp) {
                                out.push(ch);
                            } else {
                                out.push('\u{FFFD}');
                            }
                        }
                        _ => return Err(format!("invalid escape '\\{}'", esc as char)),
                    }
                }
                c if c < 0x20 => return Err("control character in string".into()),
                _ => {
                    // Decode a UTF-8 sequence starting at pos-1.
                    let start = self.pos - 1;
                    let mut len = 1;
                    if c >= 0xF0 {
                        len = 4;
                    } else if c >= 0xE0 {
                        len = 3;
                    } else if c >= 0xC0 {
                        len = 2;
                    }
                    let end = (start + len).min(self.bytes.len());
                    match std::str::from_utf8(&self.bytes[start..end]) {
                        Ok(s) => {
                            out.push_str(s);
                            self.pos = end;
                        }
                        Err(_) => return Err("invalid UTF-8 in string".into()),
                    }
                }
            }
        }
    }

    fn parse_hex4(&mut self) -> Result<u32, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err("truncated \\u escape".into());
        }
        let mut val = 0u32;
        for i in 0..4 {
            let c = self.bytes[self.pos + i];
            let d = match c {
                b'0'..=b'9' => (c - b'0') as u32,
                b'a'..=b'f' => (c - b'a' + 10) as u32,
                b'A'..=b'F' => (c - b'A' + 10) as u32,
                _ => return Err("invalid \\u escape".into()),
            };
            val = val * 16 + d;
        }
        self.pos += 4;
        Ok(val)
    }

    fn parse_arr(&mut self) -> Result<Json, String> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Arr(items));
        }
        loop {
            self.skip_ws();
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Arr(items));
                }
                _ => return Err(format!("expected ',' or ']' at offset {}", self.pos)),
            }
        }
    }

    fn parse_obj(&mut self) -> Result<Json, String> {
        self.pos += 1; // '{'
        let mut fields = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Obj(fields));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(format!("expected string key at offset {}", self.pos));
            }
            let key = self.parse_string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(format!("expected ':' at offset {}", self.pos));
            }
            self.pos += 1;
            self.skip_ws();
            let value = self.parse_value()?;
            fields.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Obj(fields));
                }
                _ => return Err(format!("expected ',' or '}}' at offset {}", self.pos)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Json;

    #[test]
    fn roundtrip() {
        let src = r#"{"model":"vulkan","messages":[{"role":"user","content":"hi\n\"quoted\" ☃"}],"stream":false,"n":3.5,"ok":true,"none":null}"#;
        let v = Json::parse(src).unwrap();
        assert_eq!(v.to_string(), src);
    }

    #[test]
    fn surrogate_pair() {
        let v = Json::parse(r#""\ud83d\ude00""#).unwrap();
        assert_eq!(v.as_str(), Some("😀"));
    }
}
