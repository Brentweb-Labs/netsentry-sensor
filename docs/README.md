# IDPS — Research Context

This project is a graduation thesis for Provil-ION, a Flemish secondary school.

> *Which common cyberattacks (DDoS, brute-force, internal network infiltration) pose the greatest threat to the Provil-ION school network, and how can software-based detection contribute to better security?*

---

## Design criteria

A school environment differs from a corporate network: limited ICT staff, constrained budgets, high wireless device density, and unpredictable user behaviour. The IDPS must meet all of the following:

| Criterion | Requirement |
|---|---|
| **Affordability** | Runs on existing hardware; no heavy licences |
| **Easy management** | Clear alerts, minimal daily tuning |
| **Exportable logging** | Readable logs for incident follow-up (GRIP basis 5 T11) |
| **Low false-positive rate** | Normal school traffic must not trigger alarms |
| **Wireless-aware** | Handles many simultaneous connections with dynamic IPs (GRIP basis 2 T3) |
| **Automatic prevention** | Blocks clear threats without requiring an admin online 24/7 |

---

## Approach

A full penetration test carries too much risk on an active school network. The chosen approach combines:

- **IDPS** (Suricata + custom services) — continuous real-time monitoring and automatic blocking
- **Vulnerability assessment** (Nuclei / OpenVAS) — periodic automated scans for misconfigurations and outdated software

Results from scans feed back into detection rules over time.

---

## Alignment with GRIP framework

The design aligns with the *Groeipad Informatieveiligheid en Privacy* (GRIP) from Kenniscentrum Digisprong:
- Logging and incident follow-up (basis 5 T11)
- Secured wireless network access (basis 2 T3)
- Formal roles for data protection and information security (basis 1 O2)
