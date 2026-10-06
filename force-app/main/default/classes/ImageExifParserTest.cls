/** Tests for ImageExifParser using in-test JPEG fixtures (no org data). */
@IsTest
private class ImageExifParserTest {
    // EXIF DateTimeOriginal 2026:09:15 10:30:00, GPS 37 47' 23" N, 122 23' 49" W
    private static final String JPEG_BIG_ENDIAN = 'ffd8ffe100ba4578696600004d4d002a00000008000287690004000000010000002688250004000000010000003800000000000190030002000000140000006e00000000000400010002000000024e00000000020005000000030000008200030002000000025700000000040005000000030000009a00000000323032363a30393a31352031303a33303a30300000000025000000010000002f00000001000008fc000000640000007a0000000100000017000000010000003100000001ffd9';
    private static final String JPEG_LITTLE_ENDIAN = 'ffd8ffe100ba45786966000049492a0008000000020069870400010000002600000025880400010000003800000000000000010003900200140000006e00000000000000040001000200020000004e00000002000500030000008200000003000200020000005700000004000500030000009a00000000000000323032363a30393a31352031303a33303a30300025000000010000002f00000001000000fc080000640000007a0000000100000017000000010000003100000001000000ffd9';
    private static final String JPEG_XMP_FIRST = 'ffd8ffe000104a46494600010100000100010000ffe1002b687474703a2f2f6e732e61646f62652e636f6d2f7861702f312e302f003c783a786d706d6574612f3effe100ba4578696600004d4d002a00000008000287690004000000010000002688250004000000010000003800000000000190030002000000140000006e00000000000400010002000000024e00000000020005000000030000008200030002000000025700000000040005000000030000009a00000000323032363a30393a31352031303a33303a30300000000025000000010000002f00000001000008fc000000640000007a0000000100000017000000010000003100000001ffd9';
    private static final String JPEG_NO_EXIF = 'ffd8ffe000104a46494600010100000100010000ffd9';
    private static final String EXPECTED_TIME = '2026-09-15T10:30:00';
    private static final Decimal EXPECTED_LAT = 37.789722;
    private static final Decimal EXPECTED_LNG = -122.396944;

    private static Blob fromHex(String hex) {
        return EncodingUtil.convertFromHex(hex);
    }

    private static void assertGps(ImageExifParser.Result result) {
        Assert.areEqual('ok', result.status, 'EXIF should be found');
        Assert.areEqual(EXPECTED_TIME, result.capturedAt, 'DateTimeOriginal should be read');
        Assert.areEqual(EXPECTED_LAT, result.lat, 'Latitude should be north-positive');
        Assert.areEqual(EXPECTED_LNG, result.lng, 'Longitude should be west-negative');
    }

    @IsTest
    static void shouldReadTimeAndGps_WhenBigEndian() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(JPEG_BIG_ENDIAN));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldReadTimeAndGps_WhenLittleEndian() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(JPEG_LITTLE_ENDIAN));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldSkipXmpSegment_WhenXmpPrecedesExif() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(JPEG_XMP_FIRST));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldReturnNone_WhenJpegHasNoExif() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(JPEG_NO_EXIF));
        Test.stopTest();
        Assert.areEqual('none', result.status, 'No EXIF segment');
        Assert.isNull(result.lat, 'No latitude');
    }

    @IsTest
    static void shouldReturnNone_WhenNotAJpeg() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(Blob.valueOf('not an image at all'));
        Test.stopTest();
        Assert.areEqual('none', result.status, 'Non-JPEG input');
    }

    @IsTest
    static void shouldReturnNone_WhenNullInput() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(null);
        Test.stopTest();
        Assert.areEqual('none', result.status, 'Null input');
    }

    @IsTest
    static void shouldReturnNone_WhenExifSegmentTruncated() {
        String truncated = JPEG_BIG_ENDIAN.substring(0, 120);
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(truncated));
        Test.stopTest();
        Assert.areEqual('none', result.status, 'Truncated segment is not parsed');
    }

    // ---- HEIC: ftyp + meta(iinf, iloc) + mdat holding the Exif item (4-byte TIFF offset, then the TIFF block) ----

    private static String hex(Integer value, Integer bytes) {
        String digits = '0123456789abcdef';
        String out = '';
        for (Integer i = 0; i < bytes * 2; i++) {
            out = digits.substring(Math.mod(value, 16), Math.mod(value, 16) + 1) + out;
            value = value / 16;
        }
        return out;
    }

    /** The TIFF block of a fixture: after FFD8, the APP1 marker and length, and 'Exif\0\0' (12 bytes), 178 bytes long. */
    private static String tiffOf(String jpegHex) {
        return jpegHex.substring(24, 24 + 2 * 178);
    }

    private static String infe(Integer version, Integer id, String itemType) {
        Integer idBytes = version >= 3 ? 4 : 2;
        return hex(8 + 4 + idBytes + 2 + 4 + 1, 4) + '696e6665' + hex(version, 1) + '000000'
            + hex(id, idBytes) + '0000' + itemType + '00';
    }

    private static String ilocItem(Integer ilocVersion, Integer id, Integer offset, Integer length) {
        return hex(id, 2) + (ilocVersion == 1 ? '0000' : '') + '0000' + '0001' + hex(offset, 4) + hex(length, 4);
    }

    /** Decoy 'hvc1' item 1 plus the Exif item 7, so the parser must match by item type. */
    private static Blob heic(String jpegHex, Integer infeVersion, Integer ilocVersion) {
        String exifItem = '00000000' + tiffOf(jpegHex); // exif_tiff_header_offset = 0
        Integer exifLength = exifItem.length() / 2;
        String ftyp = '00000018' + '66747970' + '68656963' + '00000000' + '6d696631' + '68656963';
        String iinfBody = '00000000' + '0002' + infe(infeVersion, 1, '68766331') + infe(infeVersion, 7, '45786966');
        String iinf = hex(8 + iinfBody.length() / 2, 4) + '69696e66' + iinfBody;
        Integer itemLength = 2 + (ilocVersion == 1 ? 2 : 0) + 2 + 2 + 4 + 4;
        Integer ilocSize = 8 + 4 + 1 + 1 + 2 + 2 * itemLength;
        Integer metaSize = 8 + 4 + iinf.length() / 2 + ilocSize;
        Integer mdatPayload = 24 + metaSize + 8;
        String ilocBody = hex(ilocVersion, 1) + '000000' + '44' + '00' + '0002'
            + ilocItem(ilocVersion, 1, mdatPayload + exifLength, 0) + ilocItem(ilocVersion, 7, mdatPayload, exifLength);
        String iloc = hex(8 + ilocBody.length() / 2, 4) + '696c6f63' + ilocBody;
        String metaBody = '00000000' + iinf + iloc;
        String meta = hex(8 + metaBody.length() / 2, 4) + '6d657461' + metaBody;
        String mdat = hex(8 + exifLength, 4) + '6d646174' + exifItem;
        return fromHex(ftyp + meta + mdat);
    }

    @IsTest
    static void shouldReadTimeAndGps_WhenHeicVersion2() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(heic(JPEG_BIG_ENDIAN, 2, 0));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldReadTimeAndGps_WhenHeicVersion3AndIlocVersion1() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(heic(JPEG_BIG_ENDIAN, 3, 1));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldReadTimeAndGps_WhenHeicIsLittleEndian() {
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(heic(JPEG_LITTLE_ENDIAN, 2, 0));
        Test.stopTest();
        assertGps(result);
    }

    @IsTest
    static void shouldReturnNone_WhenHeicHasNoExifItem() {
        String ftypOnly = '00000018' + '66747970' + '68656963' + '00000000' + '6d696631' + '68656963';
        Test.startTest();
        ImageExifParser.Result result = ImageExifParser.parse(fromHex(ftypOnly));
        Test.stopTest();
        Assert.areEqual('none', result.status, 'HEIC without a meta box');
    }
}
