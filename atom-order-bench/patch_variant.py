#!/usr/bin/env python3
"""Apply an unconditional atom-order variant to an OTP worktree.

  name: flatmaps order atom keys by name (term order)
  hash: flatmaps order atom keys by the atom table's name hash, ties by name
  hash1: as hash, but reads the name hash from a flat array indexed by atom
         index (one load) instead of through the atom table

Both variants make the internal hash of an atom use its name hash instead of
its atom table index (maps, process dictionary, persistent_term, enif_hash).
ETS keeps its own inlined index-based hash for immediates.
"""
import re, sys, pathlib

root, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
assert variant in ("name", "hash", "hash1")

def edit(rel, old, new, count=1):
    p = root / rel
    s = p.read_text()
    n = s.count(old)
    if n != count:
        sys.exit(f"{rel}: expected {count} match(es), found {n}: {old[:60]!r}")
    p.write_text(s.replace(old, new))

# --- internal hash: atoms hash by name hash ---------------------------------
H = "erts/emulator/beam/erl_term_hashing.c"
edit(H, """#ifdef ARCH_64
#   define IHASH_MIX_IMMEDIATE(term)""",
"""/* An atom hashes by its name hash rather than by its atom table index, so
 * that hash-dependent layouts do not depend on atom creation order. The name
 * hash is placed where the index would be, keeping the atom tag. */
static ERTS_INLINE Eterm ihash_immediate_word(Eterm term)
{
    if (is_atom(term)) {
        return ((Eterm)atom_tab(atom_val(term))->slot.bucket.hvalue
                << _TAG_IMMED2_SIZE) | _TAG_IMMED2_ATOM;
    }
    return term;
}

#ifdef ARCH_64
#   define IHASH_MIX_IMMEDIATE(term)""")
edit(H, "            IHASH_MIX_BETA(term);                                             \\",
        "            IHASH_MIX_BETA(ihash_immediate_word(term));                       \\")
edit(H, "    IHASH_MIX_ALPHA_2F32(IHASH_TYPE_IMMEDIATE, term);",
        "    IHASH_MIX_ALPHA_2F32(IHASH_TYPE_IMMEDIATE, ihash_immediate_word(term));")
edit(H, """                    IHASH_MIX_BETA(head);""",
        """                    IHASH_MIX_BETA(ihash_immediate_word(head));""")
edit(H, "        return erts_ihash_mix64(term + salt);",
        "        return erts_ihash_mix64(ihash_immediate_word(term) + salt);")
edit(H, "        return erts_ihash_mix64(term);\n",
        "        return erts_ihash_mix64(ihash_immediate_word(term));\n")

# --- JIT (x86): inline the same substitution --------------------------------
J = "erts/emulator/beam/jit/x86/instr_map.cpp"
edit(J, """    /* key_hash = key ^ (key >> 33); */
    a.mov(ARG4, ARG2);
    a.shr(ARG4, imm(33));
    a.mov(x86::rdx, ARG2);
    a.xor_(x86::rdx, ARG4);
""", """    /* An atom hashes by its name hash rather than by its atom table index,
     * see ihash_immediate_word() in erl_term_hashing.c. */
    {
        Label not_atom = a.new_label();

        a.mov(x86::rdx, ARG2);
        a.mov(ARG4, ARG2);
        a.and_(ARG4d, imm(_TAG_IMMED2_MASK));
        a.cmp(ARG4d, imm(_TAG_IMMED2_ATOM));
        a.jne(not_atom);

        a.shr(x86::rdx, imm(_TAG_IMMED2_SIZE));
        a.mov(ARG4, x86::rdx);
        a.shr(ARG4, imm(INDEX_PAGE_SHIFT));
        a.and_(x86::edx, imm(INDEX_PAGE_MASK));
        mov_imm(ARG6, (UWord)&erts_atom_table.seg_table);
        a.mov(ARG6, x86::qword_ptr(ARG6));
        a.mov(ARG6, x86::qword_ptr(ARG6, ARG4, 3));
        a.mov(ARG6, x86::qword_ptr(ARG6, x86::rdx, 3));
        a.mov(x86::rdx,
              x86::qword_ptr(ARG6, offsetof(IndexSlot, bucket.hvalue)));
        a.shl(x86::rdx, imm(_TAG_IMMED2_SIZE));
        a.or_(x86::rdx, imm(_TAG_IMMED2_ATOM));

        a.bind(not_atom);
    }

    /* key_hash = word ^ (word >> 33); */
    a.mov(ARG4, x86::rdx);
    a.shr(ARG4, imm(33));
    a.xor_(x86::rdx, ARG4);
""")

# --- flatmap atom key order --------------------------------------------------
U = "erts/emulator/beam/erl_utils.h"
if variant == "name":
    edit(U, """    if (is_atom(key_a) && is_atom(key_b)) {
        return key_a - key_b;
    }""", """    if (is_atom(key_a) && is_atom(key_b)) {
        return key_a == key_b ? 0 : erts_cmp_atoms(key_a, key_b);
    }""")
else:
    edit(U, "ERTS_GLB_INLINE Sint erts_cmp_flatmap_keys(Eterm, Eterm);",
         "ERTS_GLB_INLINE Sint erts_cmp_flatmap_keys(Eterm, Eterm);\n"
         "ERTS_GLB_INLINE Sint erts_cmp_flatmap_atoms(Eterm, Eterm);")
    edit(U, """/*
 * Only to be used for the *internal* sort order of flatmap keys.
 */
ERTS_GLB_INLINE Sint erts_cmp_flatmap_keys(Eterm key_a, Eterm key_b) {
    if (is_atom(key_a) && is_atom(key_b)) {
        return key_a - key_b;
    }""", """/*
 * The internal order of atom keys in flatmaps: by the atom table's name hash,
 * ties broken by name. Independent of atom creation order.
 */
ERTS_GLB_INLINE Sint erts_cmp_flatmap_atoms(Eterm a, Eterm b) {
    HashValue ha, hb;

    if (a == b) {
        return 0;
    }

    ha = atom_tab(atom_val(a))->slot.bucket.hvalue;
    hb = atom_tab(atom_val(b))->slot.bucket.hvalue;

    if (ha != hb) {
        return ha < hb ? -1 : 1;
    }

    return erts_cmp_atoms(a, b);
}

/*
 * Only to be used for the *internal* sort order of flatmap keys.
 */
ERTS_GLB_INLINE Sint erts_cmp_flatmap_keys(Eterm key_a, Eterm key_b) {
    if (is_atom(key_a) && is_atom(key_b)) {
        return erts_cmp_flatmap_atoms(key_a, key_b);
    }""")

C = "erts/emulator/beam/utils.c"
src = (root / C).read_text()
m = re.search(r"static\nSint compare_flatmap_atom_keys\(.*?\n}\n", src, re.S)
func = m.group(0)
if variant == "name":
    new = """static
Sint compare_flatmap_atom_keys(const Eterm* a_keys,
                               const Eterm* b_keys,
                               int n_atoms)
{
    Eterm a, b;
    int ai;

    ASSERT(n_atoms > 0);
    ASSERT(is_atom(a_keys[0]) && is_atom(b_keys[0]));
    ASSERT(is_atom(a_keys[n_atoms-1]) || is_atom(b_keys[n_atoms-1]));

    /* Atom keys are stored in term order, so the first difference decides:
     * a key the other array lacks is the smaller unique one. */
    for (ai = 0; ai < n_atoms; ai++) {
        a = a_keys[ai];
        b = b_keys[ai];
        if (a == b)
            continue;
        if (!is_atom(a))
            return +1;
        if (!is_atom(b))
            return -1;
        return erts_cmp_atoms(a, b);
    }
    return 0;
}
"""
else:
    new = func
    for old, rep in [
        ("     * The atoms are sorted by atom index (not term order).",
         "     * The atoms are sorted by erts_cmp_flatmap_atoms (not term order)."),
        ("        if (a < b) {",
         "        int c = flatmap_atom_order(a, b);\n\n        if (c < 0) {"),
        ("        else if (a > b) {", "        else if (c > 0) {"),
    ]:
        assert new.count(old) == 1, old
        new = new.replace(old, rep)
    new = """/* ERTS_UINT_MAX marks the end of an array and sorts after every atom. */
static ERTS_INLINE int flatmap_atom_order(Eterm a, Eterm b)
{
    if (a == b)
        return 0;
    if (a == ERTS_UINT_MAX)
        return +1;
    if (b == ERTS_UINT_MAX)
        return -1;
    return erts_cmp_flatmap_atoms(a, b) < 0 ? -1 : +1;
}

""" + new
(root / C).write_text(src.replace(func, new))

if variant == "hash1":
    A = "erts/emulator/beam/atom.h"
    edit(A, "extern IndexTable erts_atom_table;\n",
         "extern IndexTable erts_atom_table;\n"
         "/* Name hash of each atom, indexed by atom index. Written once when the\n"
         " * atom is created, under the atom table write lock. */\n"
         "extern Uint32 *erts_atom_name_hashes;\n")
    AC = "erts/emulator/beam/atom.c"
    edit(AC, "\nvoid\ninit_atom_table(void)\n",
         "\nUint32 *erts_atom_name_hashes;\n\nvoid\ninit_atom_table(void)\n")
    edit(AC, """		    "atom_tab", ATOM_SIZE, erts_atom_table_size, f);
""", """		    "atom_tab", ATOM_SIZE, erts_atom_table_size, f);
    erts_atom_name_hashes = erts_alloc(ERTS_ALC_T_ATOM_TABLE,
                                       erts_atom_table_size * sizeof(Uint32));
""")
    edit(AC, """    aix = index_put(&erts_atom_table, (void*) &a);
    atom_write_unlock();""", """    aix = index_put(&erts_atom_table, (void*) &a);
    erts_atom_name_hashes[aix] = (Uint32)atom_tab(aix)->slot.bucket.hvalue;
    atom_write_unlock();""")
    edit(AC, """	ix = index_put(&erts_atom_table, (void*) &a);
    (void) ix;""", """	ix = index_put(&erts_atom_table, (void*) &a);
    erts_atom_name_hashes[ix] = (Uint32)atom_tab(ix)->slot.bucket.hvalue;""")
    edit(H, "        return ((Eterm)atom_tab(atom_val(term))->slot.bucket.hvalue",
            "        return ((Eterm)erts_atom_name_hashes[atom_val(term)]")
    edit(U, "    ha = atom_tab(atom_val(a))->slot.bucket.hvalue;\n    hb = atom_tab(atom_val(b))->slot.bucket.hvalue;",
            "    ha = erts_atom_name_hashes[atom_val(a)];\n    hb = erts_atom_name_hashes[atom_val(b)];")
    edit(J, """        a.mov(ARG4, x86::rdx);
        a.shr(ARG4, imm(INDEX_PAGE_SHIFT));
        a.and_(x86::edx, imm(INDEX_PAGE_MASK));
        mov_imm(ARG6, (UWord)&erts_atom_table.seg_table);
        a.mov(ARG6, x86::qword_ptr(ARG6));
        a.mov(ARG6, x86::qword_ptr(ARG6, ARG4, 3));
        a.mov(ARG6, x86::qword_ptr(ARG6, x86::rdx, 3));
        a.mov(x86::rdx,
              x86::qword_ptr(ARG6, offsetof(IndexSlot, bucket.hvalue)));
""", """        mov_imm(ARG6, (UWord)&erts_atom_name_hashes);
        a.mov(ARG6, x86::qword_ptr(ARG6));
        a.mov(x86::edx, x86::dword_ptr(ARG6, x86::rdx, 2));
""")

print(f"patched {root} as {variant}")
