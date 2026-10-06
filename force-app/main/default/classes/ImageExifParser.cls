/**
 * Header-only EXIF reader for JPEG and HEIC/HEIF blobs. The JPEG path is an Apex port of
 * the earlier JS spike. Reads DateTimeOriginal and the GPS position; nothing is stored.
 * Bytes are read straight out of the base64 text (1.33x the file size on the heap), so a
 * 2 MB HEIC needs about 4.7 MB of the 6 MB synchronous heap.
 */
public with sharing class ImageExifParser {
    /** Parse outcome. status is 'ok' (EXIF found) or 'none' (not a JPEG, or no EXIF). */
    public class Result {
        public String status = 'none';
        public String capturedAt;
        public Decimal lat;
        public Decimal lng;
    }

    private static final Integer TAG_EXIF_IFD = 34665; // 0x8769
    private static final Integer TAG_GPS_IFD = 34853; // 0x8825
    private static final Integer TAG_DATETIME = 306; // 0x0132
    private static final Integer TAG_DATETIME_ORIGINAL = 36867; // 0x9003
    private static final Integer TAG_DATETIME_DIGITIZED = 36868; // 0x9004
    private static final Map<Integer, Integer> TYPE_SIZE = new Map<Integer, Integer>{
        1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 7 => 1, 9 => 4, 10 => 8
    };
    private static final String BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

    private final String b64;
    private final Integer len;
    private Boolean littleEndian = false;
    private Integer base = 0;
    private Integer segEnd = 0;

    private class IfdEntry {
        Integer type;
        Integer count;
        Integer valOff;
    }

    private ImageExifParser(Blob data) {
        this.b64 = EncodingUtil.base64Encode(data);
        this.len = data.size();
    }

    /**
     * @param data The JPEG or HEIC bytes (the whole file; only the metadata is walked)
     * @return Parsed result; status 'none' for null, unsupported or EXIF-less input
     */
    public static Result parse(Blob data) {
        if (data == null || data.size() < 4) {
            return new Result();
        }
        try {
            return new ImageExifParser(data).walk();
        } catch (Exception e) {
            return new Result();
        }
    }

    private Result walk() {
        if (u16(0, false) == 65496) { // 0xFFD8
            return walkJpeg();
        }
        if (len >= 12 && text(4, 4) == 'ftyp') {
            return walkHeic();
        }
        return new Result();
    }

    // ---- HEIC / HEIF (ISO base media file): the Exif item is located through meta > iinf + iloc ----

    private Result walkHeic() {
        Integer off = 0;
        while (off + 8 <= len) {
            Long size = u32(off, false);
            Integer header = 8;
            if (size == 1) {
                size = u32(off + 12, false); // 64-bit size: low word is enough for files under 4 GB
                header = 16;
            } else if (size == 0) {
                size = len - off;
            }
            if (size < header || off + size > len) {
                break;
            }
            if (text(off + 4, 4) == 'meta') {
                return readMeta(off + header + 4, Integer.valueOf(off + size)); // meta is a full box: skip version/flags
            }
            off += Integer.valueOf(size);
        }
        return new Result();
    }

    private Result readMeta(Integer start, Integer metaEnd) {
        Integer exifItemId = null;
        Integer ilocAt = null;
        Integer off = start;
        while (off + 8 <= metaEnd) {
            Long size = u32(off, false);
            if (size < 8 || off + size > metaEnd) {
                break;
            }
            String type = text(off + 4, 4);
            if (type == 'iinf') {
                exifItemId = findExifItem(off + 8, off + Integer.valueOf(size));
            } else if (type == 'iloc') {
                ilocAt = off + 8;
            }
            off += Integer.valueOf(size);
        }
        if (exifItemId == null || ilocAt == null) {
            return new Result();
        }
        Integer[] extent = findExtent(ilocAt, exifItemId); // [offset, length]
        if (extent == null || extent[1] < 12 || extent[0] + extent[1] > len) {
            return new Result();
        }
        Integer tiffStart = extent[0] + 4 + Integer.valueOf(u32(extent[0], false)); // 4-byte offset to the TIFF header
        return readTiff(tiffStart, extent[0] + extent[1]);
    }

    private Integer findExifItem(Integer start, Integer iinfEnd) {
        Integer version = u8(start);
        Integer off = start + 4 + (version == 0 ? 2 : 4); // version/flags, entry count
        while (off + 12 <= iinfEnd) {
            Long size = u32(off, false);
            if (size < 12 || off + size > iinfEnd) {
                break;
            }
            if (text(off + 4, 4) == 'infe') {
                Integer infeVersion = u8(off + 8);
                Integer idAt = off + 12;
                Integer id = infeVersion >= 3 ? Integer.valueOf(u32(idAt, false)) : u16(idAt, false);
                Integer typeAt = idAt + (infeVersion >= 3 ? 4 : 2) + 2; // item id, protection index
                if (infeVersion >= 2 && text(typeAt, 4) == 'Exif') {
                    return id;
                }
            }
            off += Integer.valueOf(size);
        }
        return null;
    }

    private Integer[] findExtent(Integer start, Integer itemId) {
        Integer version = u8(start);
        Integer sizes = u8(start + 4);
        Integer baseSizes = u8(start + 5);
        Integer offsetSize = sizes / 16;
        Integer lengthSize = Math.mod(sizes, 16);
        Integer baseOffsetSize = baseSizes / 16;
        Integer indexSize = version == 1 || version == 2 ? Math.mod(baseSizes, 16) : 0;
        Integer at = start + 6;
        Integer count = version < 2 ? u16(at, false) : Integer.valueOf(u32(at, false));
        at += version < 2 ? 2 : 4;
        for (Integer i = 0; i < count && at < len; i++) {
            Integer id = version < 2 ? u16(at, false) : Integer.valueOf(u32(at, false));
            at += version < 2 ? 2 : 4;
            Integer constructionMethod = 0;
            if (version == 1 || version == 2) {
                constructionMethod = Math.mod(u16(at, false), 16);
                at += 2;
            }
            at += 2; // data reference index
            Long baseOffset = uN(at, baseOffsetSize);
            at += baseOffsetSize;
            Integer extentCount = u16(at, false);
            at += 2;
            Integer[] first = null;
            for (Integer e = 0; e < extentCount; e++) {
                at += indexSize;
                Long extentOffset = uN(at, offsetSize);
                at += offsetSize;
                Long extentLength = uN(at, lengthSize);
                at += lengthSize;
                if (first == null) {
                    first = new Integer[]{ Integer.valueOf(baseOffset + extentOffset), Integer.valueOf(extentLength) };
                }
            }
            if (id == itemId) {
                return constructionMethod == 0 ? first : null; // only file-offset items are supported
            }
        }
        return null;
    }

    private Long uN(Integer at, Integer bytes) {
        Long value = 0;
        for (Integer i = 0; i < bytes; i++) {
            value = value * 256 + u8(at + i);
        }
        return value;
    }

    private String text(Integer at, Integer count) {
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < count; i++) {
            chars.add(u8(at + i));
        }
        return String.fromCharArray(chars);
    }

    // ---- JPEG ----

    private Result walkJpeg() {
        Integer off = 2;
        while (off + 4 <= len) {
            if (u8(off) != 255) {
                break;
            }
            Integer marker = u8(off + 1);
            while (marker == 255 && off + 2 < len) {
                off++;
                marker = u8(off + 1);
            }
            if (marker == 218 || marker == 217) { // SOS / EOI
                break;
            }
            if (marker == 1 || (marker >= 208 && marker <= 216)) {
                off += 2;
                continue;
            }
            Integer segLen = u16(off + 2, false);
            if (segLen < 2) {
                break;
            }
            Integer segmentEnd = off + 2 + segLen;
            if (marker == 225 && off + 10 <= len && isExifHeader(off + 4)) {
                if (segmentEnd > len) {
                    return new Result(); // truncated segment
                }
                return readTiff(off + 10, segmentEnd);
            }
            off = segmentEnd;
        }
        return new Result();
    }

    private Boolean isExifHeader(Integer o) {
        return u8(o) == 69 && u8(o + 1) == 120 && u8(o + 2) == 105 && u8(o + 3) == 102 && u16(o + 4, false) == 0;
    }

    private Result readTiff(Integer tiffBase, Integer tiffEnd) {
        Result out = new Result();
        base = tiffBase;
        segEnd = tiffEnd;
        Integer order = u16(base, false);
        littleEndian = order == 18761; // 0x4949
        if (!littleEndian && order != 19789) { // 0x4D4D
            return out;
        }
        if (u16(base + 2, littleEndian) != 42) {
            return out;
        }
        Map<Integer, IfdEntry> ifd0 = readIfd(Integer.valueOf(u32(base + 4, littleEndian)));
        Map<Integer, IfdEntry> exif = ifd0.containsKey(TAG_EXIF_IFD)
            ? readIfd(Integer.valueOf(u32(ifd0.get(TAG_EXIF_IFD).valOff, littleEndian)))
            : new Map<Integer, IfdEntry>();
        IfdEntry dt = exif.containsKey(TAG_DATETIME_ORIGINAL) ? exif.get(TAG_DATETIME_ORIGINAL)
            : exif.containsKey(TAG_DATETIME_DIGITIZED) ? exif.get(TAG_DATETIME_DIGITIZED)
            : ifd0.get(TAG_DATETIME);
        if (dt != null) {
            out.capturedAt = toIso(ascii(dt));
        }
        if (ifd0.containsKey(TAG_GPS_IFD)) {
            Map<Integer, IfdEntry> gps = readIfd(Integer.valueOf(u32(ifd0.get(TAG_GPS_IFD).valOff, littleEndian)));
            if (gps.containsKey(2) && gps.containsKey(4)) {
                Decimal lat = dms(gps.get(2), gps.containsKey(1) ? ascii(gps.get(1)) : 'N');
                Decimal lng = dms(gps.get(4), gps.containsKey(3) ? ascii(gps.get(3)) : 'E');
                if (lat != null && lng != null && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat == 0 && lng == 0)) {
                    out.lat = lat.setScale(6);
                    out.lng = lng.setScale(6);
                }
            }
        }
        out.status = 'ok';
        return out;
    }

    private Map<Integer, IfdEntry> readIfd(Integer ifdOff) {
        Map<Integer, IfdEntry> entries = new Map<Integer, IfdEntry>();
        Integer start = base + ifdOff;
        if (!inRange(start, 2)) {
            return entries;
        }
        Integer count = u16(start, littleEndian);
        for (Integer i = 0; i < count; i++) {
            Integer e = start + 2 + i * 12;
            if (!inRange(e, 12)) {
                break;
            }
            Integer tag = u16(e, littleEndian);
            IfdEntry entry = new IfdEntry();
            entry.type = u16(e + 2, littleEndian);
            entry.count = Integer.valueOf(u32(e + 4, littleEndian));
            Long size = (Long) (TYPE_SIZE.containsKey(entry.type) ? TYPE_SIZE.get(entry.type) : 1) * entry.count;
            Integer valOff = size <= 4 ? e + 8 : base + Integer.valueOf(u32(e + 8, littleEndian));
            if (size > segEnd || !inRange(valOff, Integer.valueOf(size))) {
                continue;
            }
            entry.valOff = valOff;
            entries.put(tag, entry);
        }
        return entries;
    }

    private Boolean inRange(Integer o, Integer n) {
        return o >= base && o + n <= segEnd;
    }

    private String ascii(IfdEntry entry) {
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < entry.count; i++) {
            Integer c = u8(entry.valOff + i);
            if (c == 0) {
                break;
            }
            chars.add(c);
        }
        return String.fromCharArray(chars);
    }

    private Decimal dms(IfdEntry entry, String ref) {
        if (entry.count < 3) {
            return null;
        }
        List<Decimal> parts = new List<Decimal>();
        for (Integer i = 0; i < 3; i++) {
            Long den = u32(entry.valOff + i * 8 + 4, littleEndian);
            parts.add(den == 0 ? 0 : Decimal.valueOf(u32(entry.valOff + i * 8, littleEndian)).divide(Decimal.valueOf(den), 10));
        }
        Decimal d = parts[0] + parts[1].divide(60, 10) + parts[2].divide(3600, 10);
        return ref == 'S' || ref == 'W' ? -d : d;
    }

    /** "YYYY:MM:DD HH:MM:SS" has no zone; kept as a naive local timestamp. */
    private static String toIso(String raw) {
        Pattern p = Pattern.compile('^(\\d{4}):(\\d{2}):(\\d{2}) (\\d{2}):(\\d{2}):(\\d{2}).*');
        Matcher m = p.matcher(raw);
        if (!m.matches() || m.group(1) == '0000') {
            return null;
        }
        return m.group(1) + '-' + m.group(2) + '-' + m.group(3) + 'T' + m.group(4) + ':' + m.group(5) + ':' + m.group(6);
    }

    private Integer u8(Integer i) {
        Integer chunk = i / 3;
        Integer at = chunk * 4;
        Integer bits = (BASE64_ALPHABET.indexOf(b64.substring(at, at + 1)) << 18) | (BASE64_ALPHABET.indexOf(b64.substring(at + 1, at + 2)) << 12);
        if (at + 2 < b64.length()) {
            bits = bits | (Math.max(BASE64_ALPHABET.indexOf(b64.substring(at + 2, at + 3)), 0) << 6);
        }
        if (at + 3 < b64.length()) {
            bits = bits | Math.max(BASE64_ALPHABET.indexOf(b64.substring(at + 3, at + 4)), 0);
        }
        return (bits >> (16 - 8 * (i - chunk * 3))) & 255;
    }

    private Integer u16(Integer i, Boolean le) {
        return le ? u8(i + 1) * 256 + u8(i) : u8(i) * 256 + u8(i + 1);
    }

    private Long u32(Integer i, Boolean le) {
        Long hi = le ? u16(i + 2, true) : u16(i, false);
        Long lo = le ? u16(i, true) : u16(i + 2, false);
        return hi * 65536 + lo;
    }
}
