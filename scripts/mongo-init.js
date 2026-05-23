// MongoDB initialization script for IDPS
// This is JavaScript, not TypeScript

// Switch to the IDPS database
db = db.getSiblingDB('idps_database');

// Create collections
db.createCollection('security_events');
db.createCollection('vulnerability_scans');
db.createCollection('compliance_reports');
db.createCollection('system_logs');
db.createCollection('scan_results');

// Create indexes for better performance
db.security_events.createIndex({ timestamp: -1 });
db.vulnerability_scans.createIndex({ scan_date: -1 });
db.compliance_reports.createIndex({ report_date: -1 });
db.system_logs.createIndex({ timestamp: -1 });
db.scan_results.createIndex({ scan_timestamp: -1 });

// Create application user with restricted permissions
db.createUser({
  user: 'idps_user',
  pwd: 'IDPS_Secure_Password123!',
  roles: [
    {
      role: 'readWrite',
      db: 'idps_database'
    }
  ]
});

// Log successful initialization
print('IDPS MongoDB initialization completed successfully');
