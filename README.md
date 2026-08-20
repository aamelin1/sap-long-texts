# Beyond READ_TEXT: Decoding SAPscript Long Texts (STXL) with SQLScript in CDS/AMDP

> Companion repository for the SAP Community blog post
> **[Beyond READ_TEXT: Decoding SAPscript Long Texts (STXL) with SQLScript in CDS/AMDP](https://community.sap.com/t5/blogs/blogworkflowpage/blog-id/technology-blog-members/article-id/180196)**.

## What is in this repository

| file | what it is |
|---|---|
| [`zclbc_ltext_decode.clas.abap`](zclbc_ltext_decode.clas.abap) | The complete AMDP class: the `decode_lines` core (cluster container parsing, LZ77 + canonical Huffman decompression, code pages) plus three thin table-function wrapper methods. One class, one decoder body. |
| [`zbc_ltext_cds_sources.abap`](zbc_ltext_cds_sources.abap) | The CDS entities: table functions `ZF_BC_LTEXT_LINES`, `ZF_BC_LTEXT_TEXT`, `ZF_FI_DOC_LTEXT` and the `ZI_BC_LONGTEXT_SEL` view consumed by the ABAP API. |
| [`stxl_decode.py`](stxl_decode.py) | A standalone Python reference decoder — a deliberately literal port of the SQLScript. Feed it the CLUSTD hex of a text (chunks trimmed to CLUSTR and concatenated): `python3 stxl_decode.py sample.hex`. Useful as an executable specification of the format and as a second implementation to cross-check against. |

The Python decoder was verified against the AMDP output character for character on live data; the SQLScript decompression was verified byte for byte against SAP's own decompression library. Object names carry our namespace conventions — rename to taste. Tested on S/4HANA 2021 (SAP_BASIS 756, HANA 2.0); on ABAP 7.58+ consider wrapping the core in a CDS scalar function instead (see below).

**Disclaimer:** the STXL on-disk format is not a public SAP contract. Treat this as read-only analytics tooling, verify against `READ_TEXT` on your own data before trusting it, and never write STXL yourself.

---

The rest of this README is the full article.


*What actually lives inside STXL, why READ_TEXT is slow by design, and how a pure SQLScript decoder makes long texts a first-class SQL citizen.*

---

Every SAP consultant has hit this wall at least once. A report needs the long text of a document — an FI item text, a PO item note, a sales order remark. The data is *right there*, in the database, in table STXL. But you cannot SELECT it. You cannot join it. You cannot filter on it. The only sanctioned door is the function module `READ_TEXT` — one call per text, one round trip per call.

For a single document that is fine. For an analytical report over 25,000 documents it is two minutes of wall-clock time spent doing something a database should do in seconds.

We recently had exactly this requirement on an S/4HANA 2021 system (SAP_BASIS 756, HANA 2.0): expose SAPscript long texts to CDS so that reports could read and filter them like ordinary columns. Materializing texts into a Z-table on a schedule was explicitly off the table — the customer wanted the real thing, decoded live from STXL, inside the database.

So we reverse-engineered the STXL storage format and implemented the full decoder — cluster container parsing, LZ77 decompression and canonical Huffman decoding — in SQLScript, wrapped in an AMDP procedure and exposed through CDS table functions. On our system it reads **~25,000 texts in 5.3 seconds**: 22 times faster than `READ_TEXT` in a loop and 2.3 times faster than SAP's own mass-reading FM.

This post walks through how the format works, why the standard FMs behave the way they do, how the in-database decoder is built, and what the numbers look like on real data. But first, some context — because we were far from the first to fight this fight.

---

## Part 0: Prior art — how the community has attacked this problem

The sheer number of blogs, Q&A threads and workarounds on this topic is the best proof that the pain is real. Before building anything, we mapped the existing approaches; here they are in one place, so you can pick the one that fits *your* constraints — several of them are perfectly good answers for narrower requirements.

| # | approach | idea | where it stops |
|---|---|---|---|
| 1 | **`READ_TEXT` in a loop** | The official API, one call per text. | Correct and universal; painfully slow at volume, invisible to CDS. |
| 2 | **`READ_TEXT_TABLE`** ([note 2261311](https://me.sap.com/notes/2261311)) | Official *mass* read: table of keys in, all lines out, one call. | 10x over the loop for free; still ships everything to the app server, still not callable from CDS. |
| 3 | **`SELECT` from STXL + `IMPORT ... FROM INTERNAL TABLE`** — the classic community trick ([Alternative to READ_TEXT, 2014](https://blogs.sap.com/2014/02/25/alternative-to-readtext-function-module/), grown from [this 2007 forum thread](https://community.sap.com/t5/application-development-discussions/mass-reading-standard-texts-stxh-stxl/m-p/7628949)) | Fetch `CLUSTR`/`CLUSTD` yourself, let the ABAP kernel deserialize. 4–5x faster than `READ_TEXT`, no FM overhead. | Decompression still runs in ABAP per text; multi-chunk texts (`SRTF2 > 0`) need careful grouping (see the dumps in that thread); unofficial; still nothing for CDS. |
| 4 | **ALV IDA calculated fields** ([Display standard text in ALV with IDA](https://community.sap.com/t5/application-development-blog-posts/display-standard-text-using-cds-in-alv-with-ida/ba-p/13442565)) | The IDA framework calls `IF_SALV_IDA_CALC_FIELD_HANDLER~CALCULATE_LINE` per displayed page; inside it you call `READ_TEXT` for the visible rows only. | Great for *display*: only the current page pays the cost. Useless for filtering, sorting or aggregating on the text — the column does not exist in the database. Same idea works in plain ABAP reports and PIVB-style frameworks: fetch texts only for the rows you are about to show. |
| 5 | **CDS virtual elements** ([with `READ_TEXT` in the exit](https://community.sap.com/t5/application-development-blog-posts/read-long-texts-using-read-text-in-cds-views/ba-p/13424464), [with `IMPORT FROM INTERNAL TABLE` in the exit](https://community.sap.com/t5/technology-blog-posts-by-members/read-material-basic-data-text-long-text-without-using-function-module-read/ba-p/13480045)) | Annotate a dummy column with `@ObjectModel.virtualElement`; a SADL exit class fills it after the database read. | Works **only** in SADL consumption: OData V2/V4, RAP, Fiori Elements. Not in ABAP `SELECT`, not in SE16N, not in another CDS on top, not in analytics. SAP itself uses this pattern in standard apps — and its authors state the limitation openly. |
| 6 | **Custom Z-table + periodic job / enhancement / SLT** ([Load and convert long texts into HANA using SLT, 2014](https://blogs.sap.com/2014/02/27/how-toload-sap-long-text-to-hana-using-slt/)) | Materialize decoded texts into a transparent table — on save via enhancement, on schedule, or in-flight in SLT transformation rules. | Full SQL power over the *copy*: joinable, filterable, indexable. The price is a second copy of the truth: latency, monitoring, storage, and a sync job that someone owns forever. |
| 7 | **SAP's own materialization: `ESH_SR_LTXT`** ([note 3048704](https://me.sap.com/notes/3048704), report `ESH_SR_LTXT_REPLICATE`, CDS `I_TextObjectPlainLongText`, [walkthrough](https://community.sap.com/t5/technology-blog-posts-by-members/accessing-long-text-of-sap-master-data-objects-or-fields-in-s4-hana-through/ba-p/13574939)) | Same idea as #6, but standard: schedule the replication report, texts land decoded in `ESH_SR_LTXT`, consume via a released CDS view; after initial replication, changes flow in near-real-time. | The list of supported `TDOBJECT`s is restricted (extending view `ESH_V_LT_CDSASOC` is explicitly discouraged by the note) — FI accounting documents, for example, [are not in it](https://community.sap.com/t5/technology-q-a/accounting-document-long-text/qaq-p/13855896). And it is still a scheduled copy. |
| 8 | **Trying to decompress in AMDP with built-ins** ([a representative Q&A](https://community.sap.com/t5/technology-q-a/calculation-in-final-internal-table-in-amdp-class/qaq-p/13733721)) | Join STXH/STXL in the AMDP and convert `CLUSTD` with `BINTOHEX` / `BINTOSTR`... | ...which cannot work: `CLUSTD` is not encoded text, it is an LZ77+Huffman-compressed serialized container. The thread ends where they all end: "use READ_TEXT in ABAP, or replicate to a custom table." |

Notice the shape of this landscape: every path either **stays in ABAP** (1–5: fast enough for display, invisible to SQL) or **materializes a copy** (6–7: full SQL, stale data, an ETL to babysit). Approach 8 is the community collectively bumping into the actual wall — the compression — and turning back.

Our requirement ("live texts, in CDS, no copies") sits exactly in the gap. The only way to fill it is to stop treating the compression as a black box: decode STXL *inside* the database. Which means we first need to understand precisely what is in there.

---

## Part 1: How long texts are actually stored

![How a SAPscript long text becomes STXL rows](imgs/ScreenShot2026-08-19%20at%2017.17.24%402x.png)

### The pipeline

When you save a long text, SAP does *not* store your lines as rows. It does this:

1. The internal table of lines (`TLINE`: `TDFORMAT` char 2 + `TDLINE` char 132) is serialized with `EXPORT ... TO DATABASE stxl` into a self-describing **ABAP cluster container** — a marker stream that carries the type name, field lengths, and the row data.
2. The whole container is compressed with SAP's **CS_LZH** algorithm — which turns out to be LZ77 with a 16 KB window plus canonical Huffman coding. Essentially deflate with SAP's own header framing.
3. A 16-byte header and a few compression service bytes are prepended.
4. The result is chopped into chunks and written to STXL rows with ascending `SRTF2`.

The key detail: **what gets compressed is not your text but the serialized structure** — including the type name, field descriptors, and every `TDLINE` padded with spaces to its full 132 characters.

### The physical layout

| field | type | key | role |
|---|---|---|---|
| MANDT | CLNT 3 | key | client |
| RELID | CHAR 2 | key | cluster area — always `'TX'` for texts |
| TDOBJECT | CHAR 10 | key | text object (`BELEG`, `EKPO`, `MATERIAL`…) |
| TDNAME | CHAR 70 | key | text name — the business key packed into a string |
| TDID | CHAR 4 | key | text ID (`0001`, `F01`…) |
| TDSPRAS | LANG 1 | key | language |
| SRTF2 | INT1 | key | chunk number: 0, 1, 2, … |
| CLUSTR | INT2 | | how many bytes of the chunk are actually used |
| CLUSTD | LRAW 7902 | | the raw binary bytes |

`CLUSTD` is a genuine binary field (VARBINARY on HANA) — it only *looks* hexadecimal in SE11/SE16. All chunks except the last one are filled completely, which is why `CLUSTR` exists: the tail of the last chunk contains garbage left over from previous writes.

Reading a text at the byte level = take all rows for the key ordered by `SRTF2`, trim each to `CLUSTR`, concatenate.

### The container header

```text
offset  value        meaning
0       FF           signature
1       03|04|05|06  container version
8..11   '1100'       code page, as ASCII digits
16..19  length       uncompressed size, little-endian
20      12           algorithm (LZH)
21..22  1F 9D        compression magic
24..    bit stream
```

If the `1F 9D` magic is absent, the data is stored *uncompressed* starting at byte 16 — which is exactly what happens with short texts, where the Huffman code tables would cost more than they save.

> **A bit of archaeology: why `1F 9D`?** These two bytes are stolen goods — they are the magic number of Unix `compress(1)`, the tool behind every `.Z` and `tar.Z` file since 1984. SAP's compression library implements two algorithms: **LZC**, which is literally the LZW variant from `compress` (the "C" stands for compress) and inherited its header honestly, and the stronger **LZH** (LZ77 + Huffman) added later — which kept the same header, magic included. So in a SAP blob `1F 9D` no longer identifies the algorithm; the byte *before* it does (`0x12` = LZH, `0x10` = LZC), and the byte after it is a fossil of compress's flags byte. The reason this matters: this is not an STXL-specific format but SAP's universal compressed-blob header. You will find the exact same `.. 12 1F 9D ..` sequence inside **SAPCAR archives**, in **REPOSRC.DATA** (compressed ABAP source code), and in compressed **DIAG (SAP GUI) and RFC protocol traffic**. And the implementation is not even secret: the library (`CsObjectInt`, files `vpa106cslzc.cpp` / `vpa108csulzh.cpp`) shipped in the open-sourced [SAP MaxDB code](https://github.com/OWASP/pysap/tree/master/pysapcompress) — which is what community projects like `pysapcompress` and the well-known [REPOSRC decompressor](https://www.daniel-berlin.de/devel/sap-dev/decompress-abap-source-code/) are built from, and what we used as the reference to verify our SQLScript port byte for byte. Crack this one format and you have cracked half of SAP's binary storage.

In the wild we met four container versions (FF03–FF06; version 6 uses different row markers and wider offsets) and four code pages: 1100 (Latin-1), 1500 (ISO 8859-5 Cyrillic — with two characters, `№` (U+2116) and `§` (U+00A7), that do not follow the simple offset rule and need a translation table), and 4102/4103 (UTF-16 BE/LE).

> **What is a code page, in one paragraph.** A byte is just a number 0–255; a code page is the agreement about which *character* each number means. In SAP code page 1100, byte `48` means `H`; in 1500 the upper half of the range maps to Cyrillic; in 4102/4103 every character takes two bytes (UTF-16). The container was written on some historical system with some code page — so the decoder cannot assume anything: it must read the code page from the header and translate the bytes accordingly, or the same bytes come out as different (wrong) characters. This is also why one system can hold texts in several encodings at once: the texts were written in different eras.

### A complete worked example: "Hello world!"

One line of text, paragraph format `*`, container version 5, code page 1100. Bytes the decoder deliberately skips are shown as dots:

```text
offs    bytes                                    meaning
0       FF                                       signature
1       05                                       version
8..11   31 31 30 30                              '1100'
16      03                                       table descriptor
22      05                                       type name length
31..35  54 4C 49 4E 45                           'TLINE'
36      AA 00 00 02                              field 1: 2 chars  -> TDFORMAT
40      AA 00 00 84                              field 2: 132 chars -> TDLINE
                                                 row size = 134 bytes
44      BB                                       row marker
45..46  2A 20                                    TDFORMAT = '*' + space
47..58  48 65 6C 6C 6F 20 77 6F 72 6C 64 21      'Hello world!'
59..178 20 20 ... 20                             120 padding spaces
179     04                                       end
```

Twelve useful characters occupy **180 bytes** of container: 44 bytes of framing plus 120 spaces of padding. This is why compression is not optional here — and why it works so well.

### LZ77 in two paragraphs

[LZ77](https://en.wikipedia.org/wiki/LZ77_and_LZ78#LZ77) rewrites the byte stream as a mix of literals and back-references **(length, distance)**: "copy N bytes starting D bytes back in the output you have already produced". Take `Hello world! Hello world!`: the first 13 bytes go out as literals, then a single token *(length 12, distance 13)* replaces the repetition — roughly 14 bits after Huffman coding instead of ~55.

The elegant trick is that **distance may be smaller than length**. The string `aaaaaaaa` encodes as literal `a` plus token *(length 7, distance 1)*: the copy proceeds byte by byte and keeps catching up with itself. And this self-overlapping copy is precisely the main source of compression in SAPscript: every `TDLINE` ends in a long run of padding spaces, and each run collapses into one token. Note also that decompression needs no match-searching at all — that expense lives entirely on the write side — which is why a decode-only implementation is realistic in SQLScript.

![LZ77: back-references, and the trick that eats SAPscript padding](imgs/LZ77%20Back-References-selection.png)

### Canonical Huffman in three paragraphs

Plain Huffman coding would require shipping the code tree with every text. The [*canonical* variant](https://en.wikipedia.org/wiki/Canonical_Huffman_code) ships **only the code lengths**: from lengths alone, both sides derive identical codes by a fixed rule (sort symbols by (length, value); first code of the shortest length is 0; +1 within a length; shift left when moving to the next length).

For "Hello world!" the letter frequencies produce lengths: `l` → 2 bits; `!`, `d`, `o`, `r` → 3 bits; space, `H`, `e`, `w` → 4 bits, and the canonical rule yields:

| length | symbols | codes |
|---|---|---|
| 2 | `l` | `00` |
| 3 | `!` `d` `o` `r` | `010` `011` `100` `101` |
| 4 | ` ` `H` `e` `w` | `1100` `1101` `1110` `1111` |

The whole word encodes in 37 bits instead of 96. Decoding needs **no tree and no pointers** — just three small arrays (`cnt[len]`, `first[len]`, `offs[len]`) and a loop:

```text
code := code * 2 + bit;  len := len + 1
if cnt[len] > 0 and 0 <= code - first[len] < cnt[len]:
    symbol := syms[ offs[len] + (code - first[len]) ]
```

The range check is literally "did I land on a leaf at this depth". No recursion, no data structures — which is exactly what makes it portable to SQLScript, where you have arrays and loops and not much else.

![Canonical Huffman: why a bit stream needs no separators](imgs/ScreenShot2026-08-19%20at%2017.18.24%402x.png)

There are actually three Huffman alphabets in the stream (literals+lengths, distances, and a small service alphabet that encodes the code lengths of the other two), exactly as in deflate. The details are mechanical; the point is that everything reduces to array arithmetic.

---

## Part 2: READ_TEXT — the front door

`READ_TEXT` is the official API and it does considerably more than decompression. Per call it: reads the STXL rows for one key, runs `IMPORT FROM DATABASE` to deserialize the cluster, checks the text object customizing (TTXOB/TTXID), consults the text memory buffer, and can invoke reference resolution and exits. Solid, correct, and — one text per call.

The cost structure follows directly: every call is a full round trip between the application server and the database, and every decompressed line travels to the app server whether you need it or not. In a loop over ~25,000 texts on our system this comes to **118 seconds** — about 4.8 ms per text, nearly all of it fixed per-call overhead.

The well-known "trick" of selecting `CLUSTR`/`CLUSTD` yourself and running `IMPORT ... FROM INTERNAL TABLE` removes the FM overhead but keeps everything else: the data still moves to the app server, the decompression still runs in ABAP, and it is still row-by-row logic. And none of it is visible to CDS.

## Part 3: READ_TEXT_TABLE — the official mass read

Fewer people know that since note **2261311** SAP ships `READ_TEXT_TABLE`: you pass a table of text keys and receive all lines in one call. One round trip instead of thousands.

On the same ~25,000 texts it takes **12.1 seconds** — a 10x improvement over the loop, essentially for free. If your code calls `READ_TEXT` in a loop today, switching to `READ_TEXT_TABLE` is the single cheapest optimization available, and you should probably stop reading here and go do it.

But two structural limits remain. First, all decompressed lines still travel to the application server — for a filter like "texts containing X" you move everything to throw most of it away. Second, it is an ABAP function module: CDS views, table functions, embedded analytics and anything else living in the database cannot call it. If the requirement is "long text as a column in CDS", no function module will ever get you there.

---

## Part 4: The in-database decoder

Everything described in Part 1 — trimming and concatenating chunks, parsing the container, LZ77, canonical Huffman, code pages — is deterministic byte arithmetic. HANA's SQLScript has byte access (`SUBSTRING` over VARBINARY), integer arithmetic, arrays and loops. That is sufficient.

The result is deliberately small: **one class, one decoder body, three thin table-function wrappers** — plus the CDS entities that expose them.

| object | role |
|---|---|
| ABAP class (AMDP) | The only place code lives. Four methods: the **core** — a read-only AMDP procedure `decode_lines( iv_clnt, it_keys, et_lines )`, table of STXH keys in, decoded lines out, STXL joined to the passed keys in one pass, ~1,200 lines of SQLScript — and three thin AMDP wrappers, one per table function below, each just building its key set and issuing a single `CALL` of the core. |
| CDS table function *LINES* | Generic access: parameters for object, ID, name, language (LIKE patterns supported), returns individual lines. |
| CDS table function *TEXT* | Same, but lines aggregated into one field per text (CLOB + a char(1333) flat variant for ALV). |
| CDS table function per scenario | Thin domain wrappers — e.g. an FI variant that drives from STXH restricted to `BELEG`/`DOC_ITEM`, applies a filter string, then calls the core. |
| ABAP API (FM over a CDS view) | A drop-in `READ_TEXT` replacement for ABAP code that wants mass reads with mask support. |

The single-class shape is worth a sentence: the decoder body exists in the system exactly once, and every consumer — generic, aggregated, domain-specific — reaches it through the same `CALL "…=>DECODE_LINES"`. During development we briefly had the body duplicated in two generated classes; unifying them removed a whole failure mode (edit one copy, forget the other) at zero runtime cost, since a wrapper adds only a key-set select on top of the core call. One SQLScript quirk to know: HANA happily lets a read-only table *function* `CALL` a read-only *procedure* — this is exactly what makes the thin-wrapper design possible.

Two design decisions deserve explanation.

**The driver pattern.** The scenario function does not decode and then filter — it filters *first* and decodes only survivors:

```sql
lt_drv = select tdobject, tdname, tdid, tdspras,
                substring( tdname,  1,  4 ) as bukrs,
                substring( tdname,  5, 10 ) as belnr,
                substring( tdname, 15,  4 ) as gjahr
           from stxh
          where mandt = :p_clnt
            and tdobject in ( 'BELEG', 'DOC_ITEM' );

lt_flt  = apply_filter( :lt_drv, :l_filter );
lt_keys = select tdobject, tdname, tdid, tdspras from :lt_flt;

call "...DECODE=>DECODE_LINES"( iv_clnt => :p_clnt,
                                it_keys => :lt_keys,
                                et_lines => lt_lines );
```

The driver starts from **STXH, not from the business document table**: documents without texts never enter the pipeline at all. `APPLY_FILTER` is SAP's documented mechanism for pushing a dynamically built predicate (assembled in ABAP with `CL_SHDB_SELTAB=>COMBINE_SELTABS` from ordinary select-options) into SQLScript. Only the keys that survive the filter reach the decoder.

**A guard against decoding the world.** If a caller passes no restriction on object, ID or name, the procedure refuses with an explicit error instead of cheerfully decompressing gigabytes of cluster data. Ask us how we know this guard is necessary.

### The honest limitation: why there are parameters

The customer's dream was a parameter-less CDS view — key columns like STXH plus a text column, where a `WHERE` on the keys limits what gets decoded. On ABAP 7.56 this is **provably impossible**, for three independent reasons we verified on the system rather than in documentation:

1. A CDS table function parameter cannot be bound to a column of another source — only literals, view parameters, session variables and constants are allowed.
2. An outer `WHERE` does not push into the function: because the body contains imperative loops, the HANA optimizer marks it `NOT UNFOLDED DUE TO IMPERATIVE LOGICS` and filters *after* full computation.
3. Associations are deferred joins, not per-row calls — nothing in 7.56 CDS executes per source row.

The construct that solves this — `DEFINE SCALAR FUNCTION`, the only CDS artifact whose arguments accept source columns — arrives in **ABAP 7.58 / S/4HANA 2023**. There, the whole package collapses to:

```abap
define view entity ZI_BC_LONGTEXT as select from stxh
{
  key tdobject, key tdname, key tdid, key tdspras,
      ZSF_LTEXT_DECODE( tdobject => tdobject, tdid => tdid,
                        tdname   => tdname,   tdspras => tdspras ) as tdtext
}
```

No parameters, filters push down into STXH like into any table, only selected rows are decoded. If you are on 7.58+, this is the form to build. On 7.56, parameterized table functions plus the driver pattern is the ceiling — and, as it turns out, a perfectly fast one.

### Does it decode correctly?

A decompression algorithm that is *almost* right is worthless, so verification was layered:

1. **Byte-for-byte decompression check.** A standalone Python port of the decoder was compared against `pysapcompress` (the community binding of SAP's own decompression library): 63 compressed clusters, identical output to the byte.
2. **Line counts** cross-checked against `STXH-TDTXTLINES`.
3. **Full-volume comparison with the SAP kernel:** on a test-system volume of ~24,000 texts, the total decoded character count matched `READ_TEXT` / `READ_TEXT_TABLE` **exactly**, once line-separator conventions were aligned.
4. An internal invariant — the end-of-stream symbol versus the uncompressed length declared in the header — is checked on every text and has never fired falsely.

All four container versions and all four code pages are covered.

---

## Part 5: The numbers

Benchmark report: same key set for all three modes (driven from STXH, objects `BELEG` + `DOC_ITEM`, identical select-options), timed with `cl_abap_runtime` high-resolution timer around the read only, minimum of several runs, first (cold) run discarded.

**Our system, all company codes: ~12,300 documents, ~25,000 texts.**

| mode | total | per text | vs. loop |
|---|---|---|---|
| **CDS / in-HANA decode** | **5.3 s** | **217 µs** | **22.2x** |
| `READ_TEXT_TABLE` | 12.1 s | 497 µs | 9.7x |
| `READ_TEXT` in a loop | 117.8 s | 4,817 µs | 1x |

![Benchmark: CDS/HANA decode vs READ_TEXT_TABLE vs READ_TEXT](imgs/ScreenShot2026-08-20%20at%2011.52.00%402x.png)

A cost model fitted on QAS data:

```text
time ≈ 0.27 ms × number_of_texts + 2.8 s × megabytes_of_CLUSTD
```

In our system FI texts happen to be very short — ~15 characters on average; that is a local specific of how our users write, not a general property of FI. It does mean, though, that this particular workload is dominated by the fixed per-text cost — which means the comparison above is close to the *worst case* for the decoder. On objects with genuinely long texts (sales order texts, PO material texts) the gap versus the FMs should widen further, because the FMs must ship every decompressed line to the application server while the decoder ships only what the query asks for.

And this is the part that no benchmark table shows: the decoder's output is a **table function result**. It joins. It filters. As one example: `WHERE tdtext LIKE '%claim%'` over a set of ~35,000 PO item texts (F01) runs in about 40 seconds *inside* HANA, and only the matches leave the database. With the FM approach the same question costs you transporting every text to the app server first. (For *interactive* content search you still want an index, i.e. materialization — the standard path being `ESH_SR_LTXT` replication. A decoder makes ad-hoc search feasible; it does not repeal the laws of physics.)

### Using it from a report

```abap
select bukrs, belnr, gjahr, buzei, hkont, wrbtr, tdtext
  from zi_fi_bseg_ltext( p_filter = @l_filter )
  where bukrs in @s_bukrs and gjahr in @s_gjahr and belnr in @s_belnr
  into table @data(lt_item).
```

One non-obvious rule: the selection must be stated **twice** — in `p_filter` for the text side (the outer `WHERE` cannot reach inside the table function, see above) and in `WHERE` for the document side. Forget the `WHERE` and you scan BSEG; forget the filter and you decode every FI text in the system. And always restrict `TDOBJECT`/`TDID` in the filter — a join will discard surplus rows, but only *after* they have been decoded.

---

## Takeaways

1. **STXL is not magic.** It is an ABAP cluster container compressed with LZ77 + canonical Huffman — a well-understood 1990s format that a few hundred lines of decode-only logic handle completely.
2. **If you call `READ_TEXT` in a loop, switch to `READ_TEXT_TABLE` today.** 10x for a one-line-per-text refactoring, fully supported, note 2261311.
3. **If you need texts in CDS/analytics, an in-database decoder is viable** — and on our system it beats even the mass FM by 2.3x while turning texts into a joinable, filterable SQL source.
4. **On ABAP 7.58+, build it as a CDS scalar function** and get the parameter-less view with true filter push-down. On 7.56, parameterized table functions with a driver + `APPLY_FILTER` are the practical ceiling.
5. **Verify against the kernel.** Byte-level comparison with SAP's own decompression and character-exact reconciliation with `READ_TEXT` on tens of thousands of texts is what separates a clever hack from something you can defend in production.

---

## Source

The full source lives right here in this repository — see the file table at the top: the AMDP class, the CDS entities, and the Python reference decoder.

*Disclaimer: the decoder relies on the observed on-disk format of STXL, which SAP does not document as a public contract. Treat it as read-only analytics tooling, verify against `READ_TEXT` on your own data, and never write STXL yourself.*
