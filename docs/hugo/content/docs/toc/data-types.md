---
title: "Data Types"
weight: 2
---

# Data Types.
In Cyber, there are primitive types and object types. Primitives are copied around by value and don't need additional heap memory or reference counts. Primitives include [Booleans](#booleans), [Numbers](#numbers), Integers, [Tags](#tags), [Tag Literals](#tags), [Errors]({{<relref "/docs/toc/errors">}}), [Static Strings](#strings), and the `none` value. Object types include [Lists](#lists), [Maps](#maps), [Strings](#strings), [Custom Objects](#objects), [Lambdas]({{<relref "/docs/toc/functions#lambdas">}}), [Fibers]({{<relref "/docs/toc/concurrency#fibers">}}), [Errors with payloads]({{<relref "/docs/toc/errors">}}), and several internal object types.

The `none` value represents an empty value. This is similar to null in other languages.

## Booleans.
Booleans can be `true` or `false`.
```cy
a = true
if a:
    print 'a is true'
```
When other value types are coerced to the boolean type, the truthy value is determined as follows.
- The `none` value is `false`.
- Other objects and values are always `true`.

## Numbers.
In Cyber, the `number` is the default number type and has a 64-bit double precision floating point format.

You can still use numbers as integers and perform arithmetic without rounding issues in a 32-bit integer range. The safe integer range is from -(2^53-1) to (2^53-1). Any integers beyond this range is not guaranteed to have a unique representation.

When performing bitwise operations, the number is first converted to an 32-bit integer.

```cy
a = 123
b = 2.34567
```

There are other number literal notations you can use.
```cy
-- Scientific notation. 
a = 123.0e4

-- Integer notations.
a = 0xFF     -- hex.
a = 0o17     -- octal.
a = 0b1010   -- binary.
```

The `int` type is a 32-bit integer and has limited support and you can only declare them in function param and return types.
```cy
func fib(n int) int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
print(fib(30))
```

Big numbers will be supported in a future version of Cyber.

## Strings.
The `string` type represents a sequence of UTF-8 characters. Under the hood, Cyber implements 6 different internal string types to optimize string operations, but the user just sees them as one type and doesn't need to care about this detail under normal usage.

Strings are **immutable**, so operations that do string manipulation return a new string. By default, small strings are interned to reduce memory footprint. To mutate an existing string, use the [StringBuffer](#string-buffer).

A string is always UTF-8 validated. [rawstrings](#rawstring) outperform strings but you'll have to validate them and take care of indexing yourself.

A single line string literal is surrounded in single quotes.
```cy
apple = 'a fruit'
```

You can escape the single quote inside the literal or use double quotes.
```cy
apple = 'Bob\'s fruit'
apple = "Bob's fruit"
```

Strings are UTF-8 encoded.
```cy
str = 'abc🦊xyz🐶'
```

Use double quotes to surround a multi-line string.
```cy
str = "line a
line b
line c"
```

You can escape double quotes inside the literal or use triple quotes.
```cy
str = "line a
line \"b\"
line c"

-- Using triple quotes.
str = '''line a
line "b"
line c
'''
```

The following escape sequences are supported:
| Escape Sequence | Code | Description |
| -- | -- | -- |
| \a | 0x07 | Terminal bell. |
| \b | 0x08 | Backspace. |
| \e | 0x1b | Escape character. |
| \n | 0x0a | Line feed character. |
| \r | 0x0d | Carriage return character. |
| \t | 0x09 | Horizontal tab character. |

The boundary of each line can be set with a vertical line character. This makes it easier to see the whitespace.
```cy
poem = "line a
       |  two spaces from the left
       |     indented further"
```

Using the index operator will return the UTF-8 character at the given character index. This is equivalent to calling the method `charAt()`.
```cy
str = 'abcd'
print str[1]     -- "b"
print str[-1]    -- "d"
```

Using the slice index operator will return a view of the string at the given start and end (exclusive) indexes. The start index defaults to 0 and the end index defaults to the character length of the string.
```cy
str = 'abcxyz'
sub = str[0..3]
print sub        -- "abc"
print str[..5]   -- "abcxy"
print str[1..]   -- "bcxyz"

-- One way to use slices is to continue a string operation.
str = 'abcabcabc'
i = str.indexChar('c')
print(i)                            -- "2"
i += 1
print(i + str[i..].indexChar('c'))  -- "5"
```

### object string
| Method | Summary |
| ------------- | ----- |
| `append(str string) string` | Deprecated: Use `concat()`. | 
| `charAt(idx number) string` | Returns the UTF-8 character at index `idx` as a single character string.  | 
| `codeAt(idx number) number` | Returns the codepoint of the UTF-8 character at index `idx`. | 
| `concat(str string) string` | Returns a new string that concats this string and `str`. | 
| `endsWith(suffix string) bool` | Returns whether the string ends with `suffix`. | 
| `index(needle string) number?` | Returns the first index of substring `needle` in the string or `none` if not found. | 
| `indexChar(needle string) number?` | Returns the first index of UTF-8 character `needle` in the string or `none` if not found. | 
| `indexCharSet(set string) number?` | Returns the first index of any UTF-8 character in `set` or `none` if not found. | 
| `indexCode(needle number) number?` | Returns the first index of UTF-8 codepoint `needle` in the string or `none` if not found. | 
| `insert(idx number, str string) string` | Returns a new string with `str` inserted at index `idx`. |
| `isAscii() bool` | Returns whether the string contains all ASCII characters. | 
| `len() number` | Returns the number of UTF-8 characters in the string. | 
| `less(str string) bool` | Returns whether this string is lexicographically before `str`. |
| `lower() string` | Returns this string in lowercase. | 
| `replace(needle string, replacement string) string` | Returns a new string with all occurrences of `needle` replaced with `replacement`. | 
| `repeat(n number) string` | Returns a new string with this string repeated `n` times. | 
| `slice(start number, end number) string` | Returns a slice into this string from `start` to `end` (exclusive) indexes. This is equivalent to using the slice index operator `[start..end]`. | 
| `startsWith(prefix string) bool` | Returns whether the string starts with `prefix`. | 
| `upper() string` | Returns this string in uppercase. | 

### String Interpolation.

You can embed expressions into string templates using braces.
```cy
name = 'Bob'
points = 123
str = 'Scoreboard: {name} {points}'
```

Escape braces with a backslash.
```cy
points = 123
str = 'Scoreboard: \{ Bob \} {points}'
```
String templates can not contain nested string templates.

### rawstring.
A `rawstring` does not automatically validate the string and is indexed by bytes and not UTF-8 characters.

Using the index operator will return the UTF-8 character starting at the given byte index. If the index does not begin a valid UTF-8 character, `error(#InvalidChar)` is returned. This is equivalent to calling the method `charAt()`.
```cy
str = rawstring('abcd').insertByte(1, 255)
print str[0]     -- "a"
print str[1]     -- error(#InvalidChar)
print str[-1]    -- "d"
```

### object rawstring
| Method | Summary |
| ------------- | ----- |
| `append(str string) string` | Deprecated: Use `concat()`. | 
| `byteAt(idx number) number` | Returns the byte value (0-255) at the given index `idx`. | 
| `charAt(idx number) string` | Returns the UTF-8 character at index `idx` as a single character string. If the index does not begin a UTF-8 character, `error(#InvalidChar)` is returned. | 
| `codeAt(idx number) number` | Returns the codepoint of the UTF-8 character at index `idx`. If the index does not begin a UTF-8 character, `error(#InvalidChar)` is returned. | 
| `concat(str string) string` | Returns a new string that concats this string and `str`. | 
| `endsWith(suffix string) bool` | Returns whether the string ends with `suffix`. | 
| `index(needle string) number?` | Returns the first index of substring `needle` in the string or `none` if not found. | 
| `indexChar(needle string) number?` | Returns the first index of UTF-8 character `needle` in the string or `none` if not found. | 
| `indexCharSet(set string) number?` | Returns the first index of any UTF-8 character in `set` or `none` if not found. |
| `indexCode(needle number) number?` | Returns the first index of UTF-8 codepoint `needle` in the string or `none` if not found. | 
| `insert(idx number, str string) string` | Returns a new string with `str` inserted at index `idx`. |
| `insertByte(idx number, byte number) string` | Returns a new string with `byte` inserted at index `idx`. | 
| `isAscii() bool` | Returns whether the string contains all ASCII characters. | 
| `len() number` | Returns the number of bytes in the string. | 
| `less(str rawstring) bool` | Returns whether this rawstring is lexicographically before `str`. |
| `lower() string` | Returns this string in lowercase. | 
| `repeat(n number) rawstring` | Returns a new rawstring with this rawstring repeated `n` times. | 
| `replace(needle string, replacement string) string` | Returns a new string with all occurrences of `needle` replaced with `replacement`. | 
| `slice(start number, end number) rawstring` | Returns a slice into this string from `start` to `end` (exclusive) indexes. This is equivalent to using the slice index operator `[start..end]`. | 
| `startsWith(prefix string) bool` | Returns whether the string starts with `prefix`. | 
| `toString() string` | Deprecated: Use `utf8()`. | 
| `upper() string` | Returns this string in uppercase. | 
| `utf8() string` | Returns a valid UTF-8 string or returns `error(#InvalidChar)`. | 

## Lists.
Lists are a builtin type that holds an ordered collection of elements. Lists grow or shrink as you insert or remove elements.
```cy
-- Construct a new list.
list = [1, 2, 3]

-- The first element of the list starts at index 0.
print list[0]    -- Prints '1'

-- Using a negative index starts at the back of the list.
print list[-1]   -- Prints '3'
```

Lists can be sliced with the range `..` clause. The sliced list becomes a new list that you can modify without affecting the original list. The end index is non-inclusive. Negative start or end values count from the end of the list.
```cy
list = [ 1, 2, 3, 4, 5 ]
list[0..0]  -- []          Empty list.
list[0..3]  -- [ 1, 2, 3 ] From start to end index.
list[3..]   -- [ 4, 5 ]    From start index to end of list. 
list[..3]   -- [ 1, 2, 3 ] From start of list to end index.
list[2..+2] -- [ 3, 4 ]    From start index to start index + amount.
```

List operations.
```cy
list = [234]
-- Append a value.
list.append 123
print list[-1]     -- Prints '123'

-- Inserting a value at an index.
list.insert(1, 345)

-- Get the length.
print list.len()  -- Prints '2'

-- Sort the list in place.
list.sort((a, b) => a < b)

-- Iterating a list.
for list each it:
    print it

-- Remove an element at a specific index.
list.remove(1)
```

### object list
| Method | Summary |
| ------------- | ----- |
| `add(val any) none` | Deprecated: Use `append()`. |
| `append(val any) none` | Appends a value to the end of the list. |
| `concat(val any) none` | Concats the elements of another list to the end of this list. |
| `insert(idx number, val any) none` | Inserts a value at index `idx`. |
| `iterator() Iterator<any>` | Returns a new iterator over the list elements. |
| `joinString(separator any) string` | Returns a new string that joins the elements with `separator`. |
| `len() number` | Returns the number of elements in the list. |
| `pairIterator() PairIterator<number, any>` | Returns a new pair iterator over the list elements. |
| `remove(idx number) none` | Removes an element at index `idx`. |
| `resize(len number) none` | Resizes the list to `len` elements. If the new size is bigger, `none` values are appended to the list. If the new size is smaller, elements at the end of the list are removed. |
| `sort(less func (a, b) bool) none` | Sorts the list with the given `less` function. If element `a` should be ordered before `b`, the function should return `true` otherwise `false`. |

## Maps.
Maps are a builtin type that store key value pairs in dictionaries.
```cy
map = { a: 123, b: () => 5 }
print map['a']

-- You can also access the map using an access expression.
print map.a

-- Map entries can be separated by the new line.
map = {
    foo: 1
    bar: 2
}
```
Entries can also follow a `{}:` block.
This gives structure to the entries and has
the added benefit of allowing multi-line lambdas.
```cy
colors = {}:
    red: 0xFF0000
    green: 0x00FF00
    blue: 0x0000FF
    dump func (c):
        print c.red
        print c.green
        print c.blue

    -- Nested map.
    darker {}: 
        red: 0xAA0000
        green: 0x00AA00
        blue: 0x0000AA
```
Map operations.
```cy
map = {}
-- Set a key value pair.
map[123] = 234

-- Get the size of the map.
print map.size()

-- Remove an entry by key.
map.remove 123

-- Iterating a list.
for map each val, key:
    print '{key} -> {value}'
```

### object map
| Method | Summary |
| ------------- | ----- |
| `iterator() Iterator<any>` | Returns a new iterator over the map elements. |
| `pairIterator() PairIterator<number, any>` | Returns a new pair iterator over the map elements. |
| `remove(key any) none` | Removes the element with the given key `key`. |
| `size() number` | Returns the number of key-value pairs in the map. |

## Objects.
Any value that isn't a primitive is an object. You can declare your own object types using the `object` keyword. Object templates are similar to structs and classes in other languages. You can declare members and methods. Unlike classes, there is no concept of inheritance at the language level.
```cy
object Node:
    value
    next

node = Node{ value: 123, next: none }
print node.value          -- '123'
```
New instances of an object template are created using the type name and braces that surround the initial member values.
When declaring methods, the first parameter must be `self`. Otherwise, it becomes a function that can only be invoked from the type's namespace.
```cy
object Node:
    value
    next

    -- A static function.
    func create():
        return Node{ value: 123, next: none }

    -- A method.
    func dump(self)
        print self.value

n = Node.create()
n.dump()
```

## Tags.
Tags are similar to enums in other languages. A new tag type can be declared with the `tagtype` keyword.
A tag value can only be one of the unique tags declared in its tag type.
By default, the tags have a unique id generated starting from 0.
```cy
tagtype Fruit:
    apple
    orange
    banana
    kiwi

fruit = Fruit#kiwi
print fruit          -- '#kiwi'
print number(fruit)  -- '3'
```
When the type of the value is known to be a tag, it can be assigned using a tag literal.
```cy
fruit = Fruit#kiwi
fruit = #orange
print(fruit == Fruit#orange)   -- 'true'
```
Tag literals by themselves also have a global unique id. When assigned to a non tag value, it becomes a tag literal value.
```cy
tagtype MyColor:
    red
    green
    blue
color = #red                 -- The variable `color` does not become a `MyColor` tag.
print(color == Color#red)    -- 'false'
print(color == #red)         -- 'true'
print number(color)          -- '123' or some arbitrary id.
```