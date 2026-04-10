package hashmap

import "base:builtin"
import "base:runtime"

import "core:fmt"
import "core:io"
import "core:time"

HASH_FREE      :: 0
HASH_TOMBSTONE :: 1

Entry :: struct($K, $V: typeid) {
	key:   K,
	value: V,
	hash:  uintptr,
}

Hash_Map :: struct($K, $V: typeid) {
	entries:   []Entry(K, V),
	hasher:    proc(key: K, seed: uintptr) -> uintptr,
	equal:     proc(a, b: K) -> bool,
	len:       int,
	allocator: runtime.Allocator,
}

make :: proc(
	$K, $V: typeid,
	hasher: proc(key: K, seed: uintptr) -> uintptr,
	equal:  proc(a, b: K) -> bool,
	cap       := 0,
	allocator := context.allocator,
) -> (hm: Hash_Map(K, V)) {
	init(&hm, hasher, equal, cap, allocator)
	return
}

init :: proc(
	hm:     ^Hash_Map($K, $V),
	hasher: proc(key: K, seed: uintptr) -> uintptr,
	equal:  proc(a, b: K) -> bool,
	cap       := 0,
	allocator := context.allocator,
) {
	assert(cap & (cap - 1) == 0)
	hm^ = {
		entries   = builtin.make([]Entry(K, V), cap, allocator),
		hasher    = hasher,
		equal     = equal,
		allocator = allocator,
	}
}

check_grow :: proc(hm: ^Hash_Map($K, $V)) -> bool {
	if hm.len * 100 < len(hm.entries) * 75 {
		return false
	}
	reserve(hm, max(len(hm.entries) * 2, 8))
	return true
}

reserve :: proc(hm: ^Hash_Map($K, $V), new_cap: int) {
	assert(new_cap & (new_cap - 1) == 0)
	if new_cap <= len(hm.entries) {
		return
	}
	hm.len = 0
	old_entries := hm.entries
	hm.entries = builtin.make([]Entry(K, V), new_cap, hm.allocator)
	for e in old_entries {
		if e.hash <= HASH_TOMBSTONE {
			continue
		}
		insert(hm, e.key, e.value)
	}
	delete(old_entries)
	return
}

insert :: proc(hm: ^Hash_Map($K, $V), key: K, value: V) {
	hash := hash_key(hm^, key)
	e    := get_entry(hm^, key, hash)

	if e != nil {
		e.value = value
		return
	}

	resized := check_grow(hm)
	if resized {
		hash = hash_key(hm^, key)
	}
	mask := uintptr(len(hm.entries) - 1)
	hm.len += 1

	for i in 0 ..< uintptr(len(hm.entries)) {
		e := &hm.entries[(hash + i) & mask]
		if e.hash == HASH_TOMBSTONE || e.hash == HASH_FREE {
			e.value = value
			e.hash  = hash
			e.key   = key
			return
		}
	}

	unreachable()
}

@(require_results)
hash_key :: proc(hm: Hash_Map($K, $V), key: K) -> uintptr {
	h := hm.hasher(key, map_seed(hm))
	if h <= HASH_TOMBSTONE {
		h += HASH_TOMBSTONE
	}
	return h
}

@(require_results)
get :: proc(hm: Hash_Map($K, $V), key: K) -> ^V {
	e := get_entry(hm, key, hash_key(hm, key))
	if e == nil {
		return nil
	} else {
		return &e.value
	}
}

remove :: proc(hm: ^Hash_Map($K, $V), key: K) -> (V, bool) {
	e := get_entry(hm, key, hash_key(hm^, key))
	if e == nil {
		return {}, false
	} else {
		v := e.value
		e^ = { hash = HASH_TOMBSTONE, }
		return v, true
	}
}

@(require_results)
get_entry :: proc(hm: Hash_Map($K, $V), key: K, hash: uintptr) -> ^Entry(K, V) {
	mask := uintptr(len(hm.entries) - 1)

	for i in 0 ..< uintptr(len(hm.entries)) {
		e := &hm.entries[(hash + i) & mask]
		if e.hash == hash && hm.equal(e.key, key) {
			return e
		}
		if e.hash == HASH_FREE {
			break
		}
	}
	return nil
}

@(require_results)
map_seed :: proc(hm: Hash_Map($K, $V)) -> uintptr {
	return runtime.map_seed_from_map_data(uintptr(raw_data(hm.entries)))
}

print_map :: proc(w: io.Writer, hm: Hash_Map($K, $V)) {
	fmt.wprint(w, "Hash_Map[")
	first := true
	for e in hm.entries {
		if e.hash <= HASH_TOMBSTONE {
			continue
		}
		if !first {
			fmt.wprintf(w, ", ")
		}
		first = false
		fmt.wprintf(w, "%v=%v", e.key, e.value)
	}
	fmt.wprint(w, "]")
}

main :: proc() {
	K :: [4]int
	V :: [4]int
	hm: Hash_Map(K, V)
	init(
		&hm,
		proc(data: K, seed: uintptr) -> uintptr {
			data := data
			return runtime.default_hasher(&data, seed, size_of(data))
		},
		proc(a, b: K) -> bool {
			return a == b
		},
	)

	N :: 1 << 24

	start: time.Time

	start = time.now()
	for i in 0 ..< N {
		i := K(i)
		insert(&hm, i, i)
	}
	for i in 0 ..< N {
		i := K(i)
		assert(get(hm, i)^ == i)
	}
	fmt.println(time.since(start))

	start = time.now()
	m: map[K]V
	for i in 0 ..< N {
		i := K(i)
		m[i] = i
	}
	for i in 0 ..< N {
		i := K(i)
		assert(m[i] == i)
	}
	fmt.println(time.since(start))
}
