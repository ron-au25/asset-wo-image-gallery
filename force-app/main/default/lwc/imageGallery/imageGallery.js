import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getImages from '@salesforce/apex/ImageGalleryController.getImages';
import getExif from '@salesforce/apex/ImageGalleryController.getExif';
import getFileData from '@salesforce/apex/ImageGalleryController.getFileData';

const PAGE_SIZE = 120;
const EXIF_BATCH = 20;
const FALLBACK_MAX_BYTES = 819200; // renditions that fail to load (Field Service mobile) are read through Apex up to this size
const HEIC_TYPES = ['HEIC', 'HEIF']; // heavy on the Apex heap, so one per call
const BATCH_MAX_BYTES = 262144; // JPEGs above this are also read one per call
const RENDITIONS = { S: 'THUMB120BY90', M: 'THUMB240BY180', L: 'THUMB720BY480' };
const GEOFENCE_METERS = 100; // photo further than this from every work location is a location violation
const TIME_FENCE_MS = 2 * 60 * 60 * 1000; // captured further than this from every scheduled start is a time violation
const VIOLATION_GROUPS = {
    both: { rank: 0, label: 'Location and time violations' },
    location: { rank: 1, label: 'Location violations' },
    time: { rank: 2, label: 'Time violations' },
    none: { rank: 3, label: 'No violations' }
};
const CARD_MIN = { S: 110, M: 160, L: 260 };

export default class ImageGallery extends NavigationMixin(LightningElement) {
    @api recordId;
    pickedId; // chosen in the picker when opened with no record (global action, app or home page)
    pickedObject = 'WorkOrder';

    isMobile = FORM_FACTOR === 'Small';
    loading = true;
    error;
    truncatedReason;
    images = [];
    records = [];
    exif = {}; // versionId -> { s, t, lat, lng }
    baseUrl = '';
    fallbackRunning = false;
    fullLoading = {};
    full = {}; // versionId -> { url } | { error }: original shown in the modal instead of downloaded
    failed = {}; // versionId -> true when the rendition is not ready
    search = '';
    size = 'M';
    sortMode = 'uploaded'; // uploaded | captured | violations | object
    sortAsc = false;
    view = 'grid'; // grid | timeline
    shown = PAGE_SIZE;
    exifProgress = null;
    selectedKey;
    exifRunning = false;

    connectedCallback() {
        this.load();
    }

    get targetId() {
        return this.recordId || this.pickedId;
    }

    get needsPicker() {
        return !this.recordId;
    }

    get objectOptions() {
        return [
            { label: 'Work Order', value: 'WorkOrder' },
            { label: 'Asset', value: 'Asset' }
        ];
    }

    get pickerKeys() {
        return [this.pickedObject]; // re-creates the picker when the object changes
    }

    get noRecordYet() {
        return !this.targetId && !this.loading;
    }

    handleObject(event) {
        this.pickedObject = event.detail.value;
        this.pickedId = undefined;
        this.images = [];
        this.records = [];
    }

    handlePick(event) {
        this.pickedId = event.detail.recordId || undefined;
        this.exif = {};
        this.images = [];
        this.records = [];
        this.load();
    }

    @api
    refresh() {
        this.load();
    }

    async load() {
        this.error = undefined;
        if (!this.targetId) {
            this.loading = false;
            return;
        }
        this.loading = true;
        try {
            const data = JSON.parse(await getImages({ recordId: this.targetId }));
            this.baseUrl = data.baseUrl || '';
            this.records = data.records || [];
            this.images = data.images || [];
            this.truncatedReason = data.truncated ? data.reason : undefined;
            this.shown = PAGE_SIZE;
            this.loading = false;
            this.loadExif(false);
        } catch (e) {
            this.error = (e && e.body && e.body.message) || (e && e.message) || 'Could not load images.';
            this.loading = false;
        }
    }

    // ---- EXIF (lazy, never blocks the grid) ----

    async loadExif(all) {
        if (this.exifRunning) return;
        this.exifRunning = true;
        const pending = this.sortedImages()
            .filter((i) => !this.exif[i.versionId]) // every image: non-EXIF files can still carry record capture fields
            .slice(0, all ? undefined : this.shown)
            .map((i) => ({
                id: i.versionId,
                heavy: HEIC_TYPES.includes((i.fileType || '').toUpperCase()) || i.size > BATCH_MAX_BYTES
            }));
        const batches = [];
        const jpegs = pending.filter((p) => !p.heavy).map((p) => p.id);
        for (let n = 0; n < jpegs.length; n += EXIF_BATCH) batches.push(jpegs.slice(n, n + EXIF_BATCH));
        pending.filter((p) => p.heavy).forEach((p) => batches.push([p.id]));
        try {
            let done = 0;
            for (const batch of batches) {
                const result = JSON.parse(await getExif({ versionIds: batch }));
                this.exif = { ...this.exif, ...result };
                done += batch.length;
                if (all) this.exifProgress = Math.min(100, Math.round((done / pending.length) * 100));
            }
        } catch (e) {
            // photo details are optional; the grid still works
        }
        this.exifProgress = null;
        this.exifRunning = false;
    }

    // ---- view model ----

    sortedImages() {
        const list = this.filteredImages();
        const captured = this.sortMode === 'captured';
        const dir = this.sortAsc ? 1 : -1;
        if (this.sortMode === 'object') {
            // source order (Asset, Work Order, line item, ...); newest upload first within a type
            const rank = new Map(list.map((i) => [i, this.objectRank(i)]));
            return list.sort((a, b) => (rank.get(a) - rank.get(b)) * dir || Date.parse(b.uploaded) - Date.parse(a.uploaded));
        }
        if (this.sortMode === 'violations') {
            // worst first; newest upload first within a type
            const rank = new Map(list.map((i) => [i, VIOLATION_GROUPS[this.violationKey(i)].rank]));
            return list.sort((a, b) => (rank.get(a) - rank.get(b)) * dir || Date.parse(b.uploaded) - Date.parse(a.uploaded));
        }
        return list.sort((a, b) => {
            const ta = captured ? this.capturedMs(a) : Date.parse(a.uploaded);
            const tb = captured ? this.capturedMs(b) : Date.parse(b.uploaded);
            if (captured && (ta === null || tb === null)) return ta === tb ? 0 : ta === null ? 1 : -1;
            return (ta - tb) * dir;
        });
    }

    filteredImages() {
        const q = this.search.trim().toLowerCase();
        if (!q) return [...this.images];
        return this.images.filter((img) => {
            const text = [img.title, img.uploadedBy, ...img.refs.flatMap((r) => this.recordText(this.records[r]))];
            return text.join(' ').toLowerCase().includes(q);
        });
    }

    recordText(rec) {
        return rec ? [rec.title, rec.subtitle, rec.objectLabel, ...(rec.breadcrumb || [])] : [];
    }

    breadcrumbText(rec) {
        return rec && rec.breadcrumb ? rec.breadcrumb.join(' › ') : '';
    }

    /** Violations of one photo: { location, time } messages, each null when the photo is fine or cannot be checked. */
    fences(img) {
        const result = { location: null, time: null };
        const info = this.exif[img.versionId];
        if (!info) return result;
        const recs = img.refs.map((r) => this.records[r]).filter(Boolean);
        const places = recs.flatMap((r) => r.places || []);
        if (info.lat !== undefined && info.lat !== null && places.length) {
            const nearest = places
                .map((p) => ({ place: p, meters: this.distanceMeters(info.lat, info.lng, p.lat, p.lng) }))
                .sort((a, b) => a.meters - b.meters)[0];
            if (nearest.meters > GEOFENCE_METERS) {
                result.location = `Taken ${this.fmtDistance(nearest.meters)} from ${nearest.place.label} (limit ${GEOFENCE_METERS} m)`;
            }
        }
        const taken = this.capturedMs(img);
        const starts = recs.flatMap((r) => r.starts || []).map((t) => Date.parse(t));
        if (taken !== null && starts.length) {
            const nearest = starts.map((t) => ({ start: t, gap: taken - t })).sort((a, b) => Math.abs(a.gap) - Math.abs(b.gap))[0];
            if (Math.abs(nearest.gap) > TIME_FENCE_MS) {
                const side = nearest.gap < 0 ? 'before' : 'after';
                result.time = `Captured ${this.fmtDuration(Math.abs(nearest.gap))} ${side} the scheduled start ${this.fmt(nearest.start)} (limit ${TIME_FENCE_MS / 3600000} h)`;
            }
        }
        return result;
    }

    /** Photos are grouped by the first record they belong to, the one shown on the card. */
    objectRank(img) {
        const name = this.records[img.refs[0]]?.objectName;
        return this.records.findIndex((r) => r.objectName === name); // records come in source order
    }

    violationKey(img) {
        const f = this.fences(img);
        if (f.location && f.time) return 'both';
        return f.location ? 'location' : f.time ? 'time' : 'none';
    }

    distanceMeters(lat1, lng1, lat2, lng2) {
        const rad = (d) => (d * Math.PI) / 180;
        const a =
            Math.sin(rad(lat2 - lat1) / 2) ** 2 +
            Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
        return 6371000 * 2 * Math.asin(Math.sqrt(a));
    }

    fmtDistance(meters) {
        return meters >= 1000 ? `${(meters / 1000).toFixed(1)} km` : `${Math.round(meters)} m`;
    }

    fmtDuration(ms) {
        const minutes = Math.round(ms / 60000);
        const days = Math.floor(minutes / 1440);
        const hours = Math.floor((minutes % 1440) / 60);
        if (days) return `${days} d ${hours} h`;
        return hours ? `${hours} h ${minutes % 60} min` : `${minutes} min`;
    }

    timeLabel(img, ms, captured) {
        const taken = this.capturedMs(img);
        if (taken !== null) return `Captured ${this.fmt(taken)}`;
        if (ms === null) return 'No capture time';
        return `${captured ? 'Captured' : 'Uploaded'} ${this.fmt(ms)}`;
    }

    capturedMs(img) {
        const info = this.exif[img.versionId];
        return info && info.t ? Date.parse(info.t) : null;
    }

    get cards() {
        const captured = this.sortMode === 'captured';
        return this.sortedImages()
            .slice(0, this.shown)
            .map((img) => this.toCard(img, captured));
    }

    toCard(img, captured) {
        const info = this.exif[img.versionId];
        const ms = captured ? this.capturedMs(img) : Date.parse(img.uploaded);
        const rec = this.records[img.refs[0]];
        const hasLocation = !!(info && info.lat !== undefined && info.lat !== null);
        const fromRecord = hasLocation && info.locSrc === 'record';
        // Fallback: the owning Work Order's address, used only when the photo has no position of its own
        const fallbackRec = hasLocation ? null : img.refs.map((r) => this.records[r]).find((r) => r && r.address);
        const mapQuery = hasLocation ? `${info.lat},${info.lng}` : fallbackRec?.address;
        const fences = this.fences(img);
        const violations = [
            fences.location && { key: 'location', short: 'Too far from site', detail: fences.location },
            fences.time && { key: 'time', short: 'Off schedule', detail: fences.time }
        ].filter(Boolean);
        return {
            key: img.versionId,
            violations,
            hasViolations: violations.length > 0,
            violationKey: violations.length === 2 ? 'both' : violations.length ? violations[0].key : 'none',
            title: img.title,
            thumb: this.full[img.versionId]?.url || this.renditionUrl(RENDITIONS[this.size], img.versionId),
            failLabel: this.full[img.versionId]?.error || 'Loading preview…',
            failed: !!this.failed[img.versionId] && !this.full[img.versionId]?.url,
            noPreview: HEIC_TYPES.includes((img.fileType || '').toUpperCase()), // Salesforce makes no rendition for HEIC
            timeLabel: this.timeLabel(img, ms, captured),
            dayKey: ms === null ? 'none' : new Date(ms).toISOString().slice(0, 10),
            dayLabel: ms === null ? 'No capture time' : new Date(ms).toLocaleDateString(undefined, { dateStyle: 'full' }),
            locationLabel: hasLocation ? `${info.lat.toFixed(4)}, ${info.lng.toFixed(4)}` : fallbackRec?.address || 'No location',
            locationTitle: hasLocation
                ? fromRecord ? 'Photo location (from file record fields)' : 'Photo location (from EXIF)'
                : 'Work order address (photo has no location)',
            hasLocation: !!mapQuery,
            locationClass: !hasLocation ? 'tap loc-fallback' : fromRecord ? 'tap loc-record' : 'tap loc-photo',
            mapQuery,
            objectName: rec ? rec.objectName : '',
            objectLabel: rec ? rec.objectLabel : 'Other',
            recordId: rec ? rec.id : null,
            recordLabel: rec ? `${rec.objectLabel} ${rec.title}` : '',
            breadcrumb: this.breadcrumbText(rec),
            extraRecords: img.refs.length > 1 ? `+${img.refs.length - 1} more` : ''
        };
    }

    fmt(ms) {
        return new Date(ms).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
    }

    get groups() {
        const cards = this.cards;
        if (this.sortMode === 'object') {
            const byObject = new Map();
            cards.forEach((c) => {
                if (!byObject.has(c.objectName)) {
                    byObject.set(c.objectName, { key: c.objectName, label: c.objectLabel, showHeader: true, cards: [] });
                }
                byObject.get(c.objectName).cards.push(c);
            });
            return [...byObject.values()];
        }
        if (this.sortMode === 'violations') {
            const byType = new Map();
            cards.forEach((c) => {
                if (!byType.has(c.violationKey)) {
                    byType.set(c.violationKey, { key: c.violationKey, label: VIOLATION_GROUPS[c.violationKey].label, showHeader: true, cards: [] });
                }
                byType.get(c.violationKey).cards.push(c);
            });
            return [...byType.values()];
        }
        if (this.view !== 'timeline') return [{ key: 'all', showHeader: false, cards }];
        const byDay = new Map();
        cards.forEach((c) => {
            if (!byDay.has(c.dayKey)) byDay.set(c.dayKey, { key: c.dayKey, label: c.dayLabel, showHeader: true, cards: [] });
            byDay.get(c.dayKey).cards.push(c);
        });
        return [...byDay.values()];
    }

    get gridStyle() {
        const min = this.isMobile && this.size === 'L' ? 9999 : CARD_MIN[this.size];
        return `grid-template-columns: repeat(auto-fill, minmax(min(${min}px, 100%), 1fr));`;
    }

    get gridClass() {
        return this.view === 'timeline' ? 'grid timeline-grid' : 'grid';
    }

    get total() {
        return this.filteredImages().length;
    }

    get countLabel() {
        const n = this.total;
        return `${n} ${n === 1 ? 'image' : 'images'}`;
    }

    get hasMore() {
        return this.total > this.shown;
    }

    get isEmpty() {
        return !this.loading && !this.error && this.total === 0;
    }

    get emptyText() {
        return this.search ? 'No images match your search.' : 'No images on this record or its related records.';
    }

    get showProgress() {
        return this.exifProgress !== null;
    }

    get sortOptions() {
        return [
            { label: 'Upload time', value: 'uploaded' },
            { label: 'Capture time', value: 'captured' },
            { label: 'Violations', value: 'violations' },
            { label: 'Object', value: 'object' }
        ];
    }

    get sizeButtons() {
        return ['S', 'M', 'L'].map((s) => ({ value: s, variant: s === this.size ? 'brand' : 'neutral' }));
    }

    get gridVariant() {
        return this.view === 'grid' ? 'brand' : 'border-filled';
    }

    get timelineVariant() {
        return this.view === 'timeline' ? 'brand' : 'border-filled';
    }

    get sortIcon() {
        return this.sortAsc ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get sortTitle() {
        return this.sortAsc ? 'Oldest first' : 'Newest first';
    }

    // ---- lightbox ----

    get selected() {
        if (!this.selectedKey) return null;
        const img = this.images.find((i) => i.versionId === this.selectedKey);
        if (!img) return null;
        const card = this.toCard(img, this.sortMode === 'captured');
        return {
            ...card,
            big: this.full[img.versionId]?.url || this.renditionUrl('THUMB720BY480', img.versionId),
            fullError: this.full[img.versionId]?.error,
            fullLoading: !!this.fullLoading[img.versionId],
            showFullButton: !this.full[img.versionId]?.url,
            uploadedLabel: `Uploaded ${this.fmt(Date.parse(img.uploaded))}${img.uploadedBy ? ` by ${img.uploadedBy}` : ''}`,
            related: img.refs.map((r) => {
                const rec = this.records[r];
                return {
                    key: `${img.versionId}-${r}`,
                    id: rec.id,
                    label: `${rec.objectLabel} ${rec.title}`,
                    breadcrumb: this.breadcrumbText(rec),
                    detail: [rec.subtitle, rec.dateLabel && rec.dateValue ? `${rec.dateLabel} ${this.fmtDate(rec.dateValue)}` : '']
                        .filter(Boolean)
                        .join(' · ')
                };
            })
        };
    }

    fmtDate(value) {
        const ms = Date.parse(value);
        return Number.isNaN(ms) ? value : this.fmt(ms);
    }

    // ---- handlers ----

    handleSearch(event) {
        this.search = event.target.value || '';
        this.shown = PAGE_SIZE;
    }

    handleSize(event) {
        this.size = event.target.dataset.size;
    }

    handleSortMode(event) {
        this.sortMode = event.detail.value;
        if (this.sortMode === 'captured' || this.sortMode === 'violations') this.loadExif(true); // captured times and positions are needed to sort
    }

    handleSortDir() {
        this.sortAsc = !this.sortAsc;
    }

    handleView(event) {
        this.view = event.currentTarget.dataset.view;
    }

    handleMore() {
        this.shown += PAGE_SIZE;
        this.loadExif(false);
    }

    handleRefresh() {
        this.exif = {};
        this.load();
    }

    handleOpen(event) {
        this.selectedKey = event.currentTarget.dataset.key;
    }

    handleClose() {
        this.selectedKey = undefined;
    }

    handleImageError(event) {
        const id = event.target.dataset.key;
        if (this.failed[id]) return;
        this.failed = { ...this.failed, [id]: true };
        this.loadFallbackThumbs();
    }

    handleRecord(event) {
        event.preventDefault();
        event.stopPropagation();
        const recordId = event.currentTarget.dataset.id;
        if (!recordId) return;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
    }

    handleMap(event) {
        event.stopPropagation();
        const { q } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: `https://maps.google.com/?q=${encodeURIComponent(q)}` }
        });
    }

    renditionUrl(rendition, versionId) {
        return `${this.baseUrl}/sfc/servlet.shepherd/version/renditionDownload?rendition=${rendition}&versionId=${versionId}`;
    }

    toDataUrl(data) {
        return `data:image/${data.mime === 'jpg' ? 'jpeg' : data.mime};base64,${data.base64}`;
    }

    /** Field Service mobile cannot load the rendition URLs: read small originals through Apex instead. */
    async loadFallbackThumbs() {
        if (this.fallbackRunning) return;
        this.fallbackRunning = true;
        for (;;) {
            const next = this.images.find(
                (i) => this.failed[i.versionId] && !this.full[i.versionId] && !this.isHeic(i) && i.size <= FALLBACK_MAX_BYTES
            );
            if (!next) break;
            try {
                const data = JSON.parse(await getFileData({ versionId: next.versionId }));
                const reason = data.reason === 'too large' ? 'File too large for preview' : 'Preview unavailable';
                this.full = { ...this.full, [next.versionId]: data.ok ? { url: this.toDataUrl(data) } : { error: reason } };
            } catch (e) {
                const message = (e && e.body && e.body.message) || (e && e.message) || 'Preview unavailable';
                this.full = { ...this.full, [next.versionId]: { error: message } };
            }
        }
        this.fallbackRunning = false;
    }

    /** Reads the original through Apex and shows it inline, so nothing is downloaded. */
    async handleFull(event) {
        event.stopPropagation();
        const versionId = this.selectedKey;
        if (!versionId || this.fullLoading[versionId]) return;
        this.fullLoading = { ...this.fullLoading, [versionId]: true };
        try {
            const data = JSON.parse(await getFileData({ versionId }));
            if (!data.ok) {
                throw new Error(data.reason === 'too large' ? 'This file is too large to show here.' : 'Could not load the photo.');
            }
            this.full = { ...this.full, [versionId]: { url: this.toDataUrl(data) } };
        } catch (e) {
            const message = (e && e.body && e.body.message) || (e && e.message) || 'Could not load the photo.';
            this.full = { ...this.full, [versionId]: { error: message } };
        }
        const next = { ...this.fullLoading };
        delete next[versionId];
        this.fullLoading = next;
    }
}
