#pragma once
#include <cstdint>
#include <cstring>
#include <string>
// libc++ 19 removed the unspecialized char_traits<T>. The upstream binary
// string relies on string operations, so provide explicit unsigned-byte traits.
struct MobileByteTraits {
  using char_type = uint8_t;
  using int_type = unsigned int;
  using off_type = std::streamoff;
  using pos_type = std::streampos;
  using state_type = std::mbstate_t;
  static void assign(char_type& a, const char_type& b) { a = b; }
  static bool eq(char_type a, char_type b) { return a == b; }
  static bool lt(char_type a, char_type b) { return a < b; }
  static int compare(const char_type* a, const char_type* b, size_t n) { return n ? std::memcmp(a,b,n) : 0; }
  static size_t length(const char_type* s) { size_t n=0; while(s[n]) ++n; return n; }
  static const char_type* find(const char_type* s, size_t n, const char_type& c) { return static_cast<const char_type*>(std::memchr(s,c,n)); }
  static char_type* move(char_type* d, const char_type* s, size_t n) { return static_cast<char_type*>(std::memmove(d,s,n)); }
  static char_type* copy(char_type* d, const char_type* s, size_t n) { return static_cast<char_type*>(std::memcpy(d,s,n)); }
  static char_type* assign(char_type* d, size_t n, char_type c) { return static_cast<char_type*>(std::memset(d,c,n)); }
  static int_type not_eof(int_type c) { return c == eof() ? 0 : c; }
  static char_type to_char_type(int_type c) { return static_cast<char_type>(c); }
  static int_type to_int_type(char_type c) { return c; }
  static bool eq_int_type(int_type a, int_type b) { return a == b; }
  static int_type eof() { return static_cast<int_type>(-1); }
};
