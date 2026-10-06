/**
 * Static definitions of the record types shown in the image gallery, and the query engine that
 * reads them. Nothing is stored: no custom metadata, fields or objects. Fields that are missing
 * or not accessible are dropped at runtime, so an absent object never breaks the gallery.
 */
public with sharing class ImageGallerySources {
    /** One link from a source object to the gallery context (field IN set). */
    public class Filter {
        public String field;
        public String setName;
        public Filter(String field, String setName) {
            this.field = field;
            this.setName = setName;
        }
    }

    /** A record type that can carry images. */
    public class Source {
        public String objectName;
        public List<Filter> filters;
        public List<String> titleFields;
        public List<String> subtitleFields;
        public List<String> dateFields;
        /** Read in system mode (WorkPlan/WorkStep OWD is Private); files are still filtered by sharing. */
        public Boolean systemMode = false;
        /** Field holding the owning Work Order, whose address is the location fallback. */
        public String workOrderField;
        public Source(String objectName, List<Filter> filters, List<String> titleFields, List<String> subtitleFields, List<String> dateFields) {
            this.objectName = objectName;
            this.filters = filters;
            this.titleFields = titleFields;
            this.subtitleFields = subtitleFields;
            this.dateFields = dateFields;
        }
    }

    /** A record ready for display. The Id is for navigation only and is never shown. */
    public class Rec {
        public Id id;
        public String objectName;
        public String objectLabel;
        public String title;
        public String subtitle;
        public String dateLabel;
        public String dateValue;
        /** Owning Work Order's address, shown when a photo has no location of its own. */
        public String address;
        public transient Id workOrderId; // transient: never serialized to the LWC
    }

    public static final String SET_ASSET = 'ASSET';
    public static final String SET_WO = 'WO';
    public static final String SET_WOLI = 'WOLI';
    public static final String SET_CASE = 'CASE';
    public static final String SET_WO_WOLI = 'WOWOLI';
    private static final List<String> ADDRESS_FIELDS = new List<String>{ 'Street', 'City', 'State', 'PostalCode', 'Country' };

    /** @return every source, in display order */
    public static List<Source> all() {
        Source workPlan = wo(new Source('WorkPlan', f('WorkOrderId', SET_WO), t('Name'), t(), t('CreatedDate')), 'WorkOrderId');
        workPlan.systemMode = true;
        Source workStep = wo(new Source('WorkStep', f('WorkOrderId', SET_WO), t('Name'), t('Status'), t('StartTime', 'CreatedDate')), 'WorkOrderId');
        workStep.systemMode = true;
        return new List<Source>{
            new Source('Asset', f('Id', SET_ASSET), t('Name'), t('SerialNumber', 'Status'), t('InstallDate', 'CreatedDate')),
            wo(new Source('WorkOrder', f('Id', SET_WO), t('WorkOrderNumber'), t('Subject', 'Status'), t('StartDate', 'CreatedDate')), 'Id'),
            wo(new Source('WorkOrderLineItem', f('Id', SET_WOLI), t('LineItemNumber'), t('Subject', 'Status'), t('StartDate', 'CreatedDate')), 'WorkOrderId'),
            workPlan,
            workStep,
            wo(new Source('ServiceAppointment', f('ParentRecordId', SET_WO_WOLI), t('AppointmentNumber'), t('Subject', 'Status'), t('ActualStartTime', 'SchedStartTime', 'CreatedDate')), 'ParentRecordId'),
            new Source('Case', f('Id', SET_CASE), t('CaseNumber'), t('Subject', 'Status'), t('CreatedDate')),
            wo(new Source('Measure_Point__c', new List<Filter>{ new Filter('Asset__c', SET_ASSET), new Filter('Work_Order__c', SET_WO) },
                t('Component_Name__c', 'Name'), t('Measure_Type__c', 'Measure_Value__c', 'Defect_Location__c'), t('Update_Date__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('Work_Delay__c', f('Work_Order__c', SET_WO), t('Name__c', 'Name'), t('Delay_Reason__c'), t('Start_Date__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('Safety_Incident__c', f('Work_Order__c', SET_WO), t('Subject__c', 'Name'), t('Injury_Type__c', 'Status__c'), t('Incident_Date__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('Time_Report__c', f('Work_Order__c', SET_WO), t('Name'), t('Resource_Name__c', 'Status__c'), t('Start_Time__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('RS_PurchaseOrder__c', f('Work_Order__c', SET_WO), t('PO_Number__c', 'Name'), t('Supplier_Name__c', 'Status__c'), t('Document_Date__c', 'CreatedDate')), 'Work_Order__c'),
            new Source('SDO_SCOM_Replacement_Parts__c', f('Asset__c', SET_ASSET), t('Name'), t(), t('CreatedDate'))
        };
    }

    /**
     * Sets each record's address to its owning Work Order's address (Street, City, State, PostalCode,
     * Country). Coordinates are not used. Inaccessible address fields are skipped.
     * @param records Records returned by fetch
     */
    public static void applyWorkOrderAddresses(List<Rec> records) {
        Set<Id> workOrderIds = new Set<Id>();
        for (Rec rec : records) {
            if (rec.workOrderId != null) {
                workOrderIds.add(rec.workOrderId);
            }
        }
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.WorkOrder.fields.getMap();
        List<String> selected = new List<String>();
        for (String name : ADDRESS_FIELDS) {
            if (usable(fields, name)) {
                selected.add(name);
            }
        }
        if (workOrderIds.isEmpty() || selected.isEmpty()) {
            return;
        }
        Map<Id, String> addressById = new Map<Id, String>();
        for (SObject row : Database.queryWithBinds(
            'SELECT Id, ' + String.join(selected, ', ') + ' FROM WorkOrder WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => workOrderIds },
            AccessLevel.USER_MODE
        )) {
            String address = formatAddress(row, selected);
            if (address != null) {
                addressById.put(row.Id, address);
            }
        }
        for (Rec rec : records) {
            if (rec.workOrderId != null) {
                rec.address = addressById.get(rec.workOrderId);
            }
        }
    }

    private static String formatAddress(SObject row, List<String> selected) {
        List<String> parts = new List<String>();
        for (String name : selected) {
            String text = text(row, name);
            if (text != null) {
                parts.add(text.trim());
            }
        }
        return parts.isEmpty() ? null : String.join(parts, ', ');
    }

    private static Source wo(Source source, String field) {
        source.workOrderField = field;
        return source;
    }

    /**
     * Reads the records of one source that belong to the context.
     * @param source The source definition
     * @param sets Context Ids by set name
     * @param maxRows Row cap for this source
     * @return Display records; empty when the object/fields are unavailable
     */
    public static List<Rec> fetch(Source source, Map<String, Set<Id>> sets, Integer maxRows) {
        List<Rec> result = new List<Rec>();
        Schema.SObjectType type = Schema.getGlobalDescribe().get(source.objectName);
        if (type == null || maxRows <= 0) {
            return result;
        }
        Map<String, Schema.SObjectField> fields = type.getDescribe().fields.getMap();
        List<String> clauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        for (Filter filter : source.filters) {
            Set<Id> ids = sets.get(filter.setName);
            if (ids != null && !ids.isEmpty() && usable(fields, filter.field)) {
                String bind = 'b' + clauses.size();
                clauses.add(filter.field + ' IN :' + bind);
                binds.put(bind, ids);
            }
        }
        if (clauses.isEmpty()) {
            return result;
        }
        List<String> selected = new List<String>{ 'Id', 'CreatedDate' };
        List<String> wanted = fieldNames(source);
        if (source.workOrderField != null) {
            wanted.add(source.workOrderField);
        }
        for (String name : wanted) {
            if (usable(fields, name) && !selected.contains(name)) {
                selected.add(name);
            }
        }
        String soql = 'SELECT ' + String.join(selected, ', ') + ' FROM ' + source.objectName
            + ' WHERE ' + String.join(clauses, ' OR ') + ' ORDER BY CreatedDate DESC LIMIT ' + maxRows;
        List<SObject> rows = source.systemMode ? new SystemReader().query(soql, binds) : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
        for (SObject row : rows) {
            result.add(toRec(source, type, fields, row));
        }
        return result;
    }

    private static Rec toRec(Source source, Schema.SObjectType type, Map<String, Schema.SObjectField> fields, SObject row) {
        Rec rec = new Rec();
        rec.id = row.Id;
        rec.objectName = source.objectName;
        rec.objectLabel = type.getDescribe().getLabel();
        rec.title = firstText(row, source.titleFields) ?? rec.objectLabel;
        List<String> parts = new List<String>();
        for (String name : source.subtitleFields) {
            String text = text(row, name);
            if (text != null) {
                parts.add(text);
            }
        }
        rec.subtitle = parts.isEmpty() ? null : String.join(parts, ' · ');
        Object owner = source.workOrderField == null || !usable(fields, source.workOrderField) ? null : row.get(source.workOrderField);
        if (owner instanceof Id && ((Id) owner).getSObjectType() == WorkOrder.SObjectType) {
            rec.workOrderId = (Id) owner; // ServiceAppointment parents can be line items; those are skipped
        }
        for (String name : source.dateFields) {
            String text = text(row, name);
            if (text != null && usable(fields, name)) {
                rec.dateLabel = fields.get(name.toLowerCase()).getDescribe().getLabel();
                rec.dateValue = text;
                break;
            }
        }
        return rec;
    }

    private static String firstText(SObject row, List<String> names) {
        for (String name : names) {
            String text = text(row, name);
            if (text != null) {
                return text;
            }
        }
        return null;
    }

    private static String text(SObject row, String name) {
        Object value;
        try {
            value = row.get(name);
        } catch (Exception e) {
            return null; // field was not selected (unavailable)
        }
        if (value == null) {
            return null;
        }
        String text = value instanceof Datetime ? ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : String.valueOf(value);
        return String.isBlank(text) ? null : text;
    }

    private static Boolean usable(Map<String, Schema.SObjectField> fields, String name) {
        Schema.SObjectField field = fields.get(name.toLowerCase());
        return field != null && field.getDescribe().isAccessible();
    }

    private static List<String> fieldNames(Source source) {
        List<String> names = new List<String>();
        names.addAll(source.titleFields);
        names.addAll(source.subtitleFields);
        names.addAll(source.dateFields);
        return names;
    }

    private static List<Filter> f(String field, String setName) {
        return new List<Filter>{ new Filter(field, setName) };
    }

    private static List<String> t(String a, String b, String c) {
        return new List<String>{ a, b, c };
    }

    private static List<String> t(String a, String b) {
        return new List<String>{ a, b };
    }

    private static List<String> t(String a) {
        return new List<String>{ a };
    }

    private static List<String> t() {
        return new List<String>();
    }

    /**
     * System-mode reads for WorkPlan and WorkStep, whose OWD is Private. Only display text is
     * returned; image files are still filtered by the running user's sharing.
     */
    public without sharing class SystemReader {
        public List<SObject> query(String soql, Map<String, Object> binds) {
            return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
        }
    }
}
