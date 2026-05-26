//! Business logic services for network-filter.

use std::ffi::CStr;
use std::mem;
use std::net::Ipv4Addr;

/// Perform reverse DNS lookup using libc.
pub fn reverse_dns_blocking(ip: &str) -> Vec<String> {
    let addr: Ipv4Addr = match ip.parse() {
        Ok(a) => a,
        Err(_) => return vec![],
    };

    let octets = addr.octets();

    unsafe {
        let mut sockaddr: libc::sockaddr_in = mem::zeroed();
        sockaddr.sin_family = libc::AF_INET as libc::sa_family_t;
        sockaddr.sin_addr.s_addr = u32::from_ne_bytes(octets);

        let mut host = vec![0 as libc::c_char; 1025];

        let ret = libc::getnameinfo(
            &sockaddr as *const libc::sockaddr_in as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            host.as_mut_ptr(),
            1024,
            std::ptr::null_mut(),
            0,
            libc::NI_NAMEREQD,
        );

        if ret == 0 {
            if let Ok(hostname) = CStr::from_ptr(host.as_ptr()).to_str() {
                let name = hostname.to_string();
                if name != ip {
                    return vec![name];
                }
            }
        }
    }

    vec![]
}

/// Restore active blocked IPs from MongoDB on startup.
pub async fn restore_active_blocks(
    mongo_client: &mongodb::Client,
    network_filter: &std::sync::Arc<idps_network_filter::NetworkFilter>,
) -> Result<(), Box<dyn std::error::Error>> {
    use mongodb::bson::doc;

    let collection = mongo_client
        .database("idps")
        .collection::<crate::models::PersistentBlockedIp>("blocked_ips");
    let mut cursor = collection.find(doc! { "active": true }).await?;

    use futures_util::TryStreamExt;
    while let Some(blocked) = cursor.try_next().await? {
        let blocked_at = blocked
            .blocked_at_dt
            .map(|dt| dt.to_system_time())
            .map(chrono::DateTime::<chrono::Utc>::from)
            .unwrap_or_else(chrono::Utc::now);
        let expires_at = blocked
            .expires_at_dt
            .map(|dt| dt.to_system_time())
            .map(chrono::DateTime::<chrono::Utc>::from)
            .unwrap_or_else(chrono::Utc::now);

        if let Err(e) = network_filter
            .restore_blocked_ip(
                &blocked.ip,
                &blocked.reason,
                blocked.threat_level as u8,
                &blocked.source,
                blocked_at,
                expires_at,
            )
            .await
        {
            log::error!("Failed to restore active block for {}: {}", blocked.ip, e);
        }
    }
    Ok(())
}
