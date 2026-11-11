# MICRO Lab Research Assistant Onboarding Agreement and Operations Manual

**Version:** 1.0 — October 2026  
**Applies to:** Undergraduate and graduate research assistants, technicians, interns, visiting students, volunteers, and other trainees  
**Research scope:** Nanotechnology, nanoelectronics, semiconductor devices, integrated hardware, fabrication, characterization, packaging, and hardware–software co-design

> **Adoption note.** This document is a complete operational template for a U.S. university laboratory. It is not a substitute for an institution’s employment contract, collective-bargaining agreement, student handbook, intellectual-property policy, chemical hygiene plan, export-control determination, or legal advice. The institution’s approved policies and sponsor terms control whenever they conflict with this document. The Principal Investigator (PI), Environmental Health and Safety (EHS), research compliance office, export-control office, human resources, and institutional counsel should approve the document before formal adoption.

## Executive overview

The MICRO Lab’s purpose is to turn nanoscale material and device concepts into measurable, reproducible, and manufacturable semiconductor hardware. Research assistants are therefore trained not merely to “run experiments,” but to connect five levels of inquiry: material properties, device physics, fabrication processes, circuits and architectures, and system-level performance.

The field is moving beyond simple geometric transistor scaling toward atomically thin channels, gate-all-around structures, monolithic three-dimensional integration, chiplets and advanced packaging, and computing-in-memory. Recent work has demonstrated wafer-scale two-tier MoS2 integration with more than 10,000 field-effect transistors per tier, three-tier mixed MoS2/WSe2 integration, and functional sensing and storage circuits. Other work has shown 3D III–V/Si mixed-signal integration in which InGaAs high-electron-mobility transistors coexist with underlying silicon CMOS, illustrating how heterogeneous material systems can combine RF performance with dense digital control.[^1][^2]

At the architecture level, analog in-memory hardware has progressed from proof-of-concept arrays to chips containing 35 million phase-change-memory devices, with reported peak sustained efficiency of 12.4 TOPS/W on speech workloads. Advanced chiplet systems and shrinking die-to-die interconnect pitches provide a complementary path: instead of forcing every function onto one monolithic die, future systems can combine optimized compute, memory, RF, sensing, and photonic dies in two- and three-dimensional packages.[^3][^4][^5][^6]

The lab’s direction is consequently **device-to-system translation**: experimentally rigorous nanoelectronic devices, integrated through scalable processes, benchmarked in circuits, and evaluated under realistic variability, reliability, energy, thermal, and manufacturing constraints.

## Mission and scope

### Mission statement

**The MICRO Lab invents, fabricates, characterizes, and integrates nanoscale semiconductor technologies that improve computing density, energy efficiency, sensing, communication, and hardware intelligence. The lab trains researchers to produce safe, ethical, reproducible, and industry-relevant work from material synthesis through system demonstration.**

### Core research questions

1. **How far can electrostatic scaling continue?** The lab studies atomically thin channels, nanosheets, nanowires, gate-all-around devices, contacts, dielectrics, doping, interfaces, and variability. Two-dimensional semiconductors offer strong electrostatic control at sub-10-nm dimensions, but contacts, dielectric integration, doping, wafer uniformity, and credible benchmarking remain decisive barriers to “lab-to-fab” transition.[^7][^8]
2. **How can useful functions be stacked vertically?** The lab develops low-temperature and transfer-compatible processes for monolithic 3D integration of transistors, memory, sensors, RF elements, and interconnects. Wafer-scale 2D FET stacks and heterogeneous III–V/Si circuits indicate that vertical integration can increase density and combine otherwise incompatible materials.[^2][^1]
3. **How should memory and computation be reorganized?** The lab investigates memristive, phase-change, ferroelectric, and related nonvolatile devices for computing-in-memory and neuromorphic systems. Computing-in-memory seeks to reduce data movement by performing logic or multiply–accumulate operations in or near memory cells.[^9]
4. **How can heterogeneous hardware become manufacturable?** The lab studies chiplets, hybrid bonding, through-wafer vias, thermal management, testability, yield, and die-to-die interfaces. UCIe-oriented 3D architectures and high-aspect-ratio interposer vias show both the opportunity and the manufacturing challenges of dense package-level integration.[^10][^3]
5. **How can claims survive independent replication?** Every result must connect raw data, process history, calibration, analysis code, and stated uncertainty. Reproducible research requires traceability from reduced results back to original data and documentation sufficient to recreate the work independently.[^11][^12]

## Research roadmap

### Near term: 0–2 years

- Establish standardized fabrication travelers, sample identifiers, electrical-test protocols, and uncertainty-aware benchmarks.
- Build reliable baseline MOSFET, 2D FET, resistive-memory, or sensor test structures before introducing novel materials or process steps.
- Quantify contact resistance, mobility, subthreshold behavior, leakage, hysteresis, endurance, retention, device-to-device variability, yield, and thermal sensitivity using pre-registered analysis definitions.
- Create reusable instrument-control and analysis packages with version control, automated metadata capture, unit tests, and immutable raw-data storage.
- Demonstrate small circuits or arrays that prove a device-level advantage survives interconnects, peripherals, parasitics, and variation.

### Medium term: 2–5 years

- Integrate nanoscale devices into two- or three-tier systems using low-thermal-budget processing, transfer, hybrid bonding, or chiplet assembly.
- Co-design devices and circuits for application-level metrics such as energy per operation, latency, bandwidth density, signal-to-noise ratio, classification accuracy, or RF figure of merit.
- Develop process-control monitors and statistical process control sufficient to distinguish a real physical improvement from wafer, lot, operator, or measurement effects.
- Establish external fabrication, packaging, and characterization collaborations while preserving publication freedom, intellectual-property obligations, and export-control compliance.

### Long term: 5+ years

- Deliver experimentally validated, vertically integrated hardware that combines logic, memory, sensing, RF, or photonic functions.
- Translate promising nanodevices into reproducible wafer- or chip-scale platforms rather than isolated “hero devices.”
- Build energy-efficient specialized hardware in which the material, device, circuit, architecture, and algorithm are optimized together.
- Release well-documented datasets, process modules, models, and open research artifacts when sponsor, intellectual-property, security, and export rules permit.

## Evidence shaping the roadmap

| Research milestone | Demonstrated impact | Direction for MICRO Lab |
|---|---|---|
| Critical assessment of 2D transistors, 2021 | Identified contacts, channels, dielectrics, substrates, short-channel performance, and reliable benchmarking as central lab-to-fab challenges.[^7] | Require complete device stacks and honest cross-study metrics, not mobility or one “best” curve alone. |
| Scaled MoS2 FETs, 2021 | Demonstrated 30-nm channels, 13-nm contacts, and a path for comparison with silicon gate-all-around devices.[^13] | Couple dimensional scaling to contact, oxide, electrostatic, and power-performance-area analysis. |
| GeSn gate-all-around p-FETs, 2021 | Demonstrated sub-3-nm nanowire width with a reported 66 mV/decade subthreshold swing.[^14] | Explore gate-all-around electrostatics and quantum-confinement-aware design. |
| III–V/Si 3D integration, 2022 | Integrated InGaAs RF devices over silicon mixed-signal CMOS while preserving operation of the bottom circuits.[^1] | Pursue heterogeneous stacks where each material performs the function it does best. |
| Attojoule-switching perspective, 2022 | Identified materials, transistor structures, lithography, monolithic 3D, design–technology co-optimization, alternative switching, and cryogenic operation as complementary scaling paths.[^15] | Judge projects by energy and system utility, not dimensions alone. |
| Hardware memristor CNN, 2020 | Integrated eight 2,048-cell arrays and reported greater than 96% MNIST accuracy with substantially improved energy efficiency over the comparison GPU.[^16] | Test complete hardware pipelines and account for device imperfection in training and inference. |
| Analog-AI chip, 2023 | Integrated 35 million phase-change-memory devices across 34 tiles and reached up to 12.4 TOPS/W peak sustained performance.[^5] | Scale arrays, peripheral circuits, communication, and software mapping together. |
| Computing-in-memory taxonomy, 2023 | Unified logic and multiply–accumulate forms of computing-in-memory by how memory cells participate in computation.[^9] | Select device technologies from the required computational primitive, rather than forcing one device into every use case. |
| Wafer-scale 3D 2D-FET integration, 2024 | Demonstrated more than 10,000 MoS2 FETs per tier in a monolithic two-tier stack and additional three-tier structures.[^2] | Make low-temperature 3D process integration and tier-to-tier yield core competencies. |
| UCIe-3D system-in-package, 2024 | Proposed and evaluated die-to-die architectures down to 1 µm bump pitch, emphasizing latency, bandwidth, and energy trade-offs.[^3] | Connect nanofabrication to package interconnect, thermal, test, and protocol constraints. |
| Low-power 2D GAA logic, 2025 | Reported wafer-scale multilayer single-crystalline Bi2O2Se gate-all-around devices integrated at low temperature, operating at 0.5 V.[^17] | Investigate vertically stacked channels and integrated native dielectrics while independently validating reliability and process compatibility. |

No single paper establishes commercial readiness. The combined evidence instead supports a disciplined progression from isolated device behavior to wafer uniformity, circuits, multilayer integration, packaging, and application-level demonstrations.

## Roles and accountability

| Role | Primary authority | Required responsibilities |
|---|---|---|
| Principal Investigator | Scientific direction, personnel authorization, publication and sponsor accountability | Approves projects, mentors, risk level, access, dissemination, and corrective actions; ensures resources and supervision. |
| Lab manager or cleanroom manager | Facility operations and access control | Maintains training records, equipment status, chemical inventory, emergency readiness, maintenance, and access permissions. |
| Project mentor | Day-to-day technical supervision | Defines tasks and acceptance criteria; reviews notebooks, code, data, and safety controls; conducts weekly feedback. |
| Safety lead | Lab-specific implementation of institutional EHS rules | Coordinates SOPs, hazard assessments, inspections, incident review, and stop-work follow-up; does not replace EHS authority. |
| Data/code steward | Research record and computing practices | Maintains repositories, permissions, backups, schemas, naming standards, and release packages. |
| Research assistant | Authorized work and accurate documentation | Works only within training and authorization; follows SOPs; records all work; reports deviations, hazards, incidents, and uncertainty promptly. |

A research assistant may never be assigned responsibility that exceeds the person’s demonstrated training, authorization, or ability to obtain immediate supervision.

## Authorization levels

- **Level 0 — Observer:** May attend meetings and enter approved nonhazardous areas while escorted; may not operate equipment or handle samples, chemicals, gases, lasers, high voltage, vacuum systems, or controlled data.
- **Level 1 — Supervised trainee:** May perform specifically listed tasks while an authorized mentor is physically present and attentive.
- **Level 2 — Independent user:** May perform listed routine procedures without continuous observation after written qualification; must comply with buddy, working-hours, or check-in rules.
- **Level 3 — Advanced operator:** May execute listed higher-complexity procedures, train Level 0–1 users when designated, and respond within the boundaries of approved SOPs.
- **Level 4 — Process or instrument owner:** May approve routine recipes, coordinate maintenance, manage logs, and recommend qualifications; only the facility manager, PI, or institutional authority may grant final access.

Authorization is **task-specific and equipment-specific**. Qualification on one wet bench, deposition tool, probe station, laser, or etcher does not authorize use of another.

## Onboarding sequence

### Before access

1. Confirm appointment classification, supervisor, project, expected weekly effort, start/end dates, compensation or academic credit, and institutional status.
2. Complete institutional onboarding, emergency contact, accessibility, payroll or volunteer authorization, and required background or identity checks.
3. Complete required Responsible and Ethical Conduct of Research training. NSF-supported institutions must maintain appropriate training and oversight plans for covered undergraduates, graduate students, postdoctoral researchers, faculty, and other senior personnel; the requirement also includes mentorship training.[^18]
4. Complete laboratory safety, chemical hygiene, hazardous-waste, cleanroom, nanomaterial, electrical, laser, compressed-gas, cryogenic, biosafety, radiation, machine-shop, and other modules applicable to assigned tasks.
5. Complete research-security, cybersecurity, export-control, controlled-unclassified-information, and sponsor-specific training when applicable. NSF research-security training addresses cybersecurity, international collaboration, foreign interference, proper use of funds, disclosure, conflicts of commitment, and conflicts of interest.[^19]
6. Receive institutional accounts and least-privilege access to approved storage, electronic notebooks, code repositories, instruments, and facilities.
7. Read this manual, the lab chemical hygiene plan, applicable SOPs, emergency action plan, data-management plan, and project charter.
8. Sign the agreement at the end of this document. **No signature overrides missing safety training or written equipment authorization.**

### First day

- Tour exits, assembly locations, alarm stations, safety showers, eyewashes, spill kits, fire extinguishers, emergency power-off controls, first-aid resources, chemical storage, waste streams, and restricted areas.
- Identify the PI, day-to-day mentor, lab manager, safety lead, data steward, and institutional reporting contacts.
- Review stop-work authority, incident reporting, prohibited lone work, after-hours rules, and whom to call before attempting cleanup.
- Receive the project charter, initial reading list, notebook, file structure, sample-ID convention, and first 30-day deliverables.

### First week

- Observe each assigned process from setup through cleanup and data transfer.
- Complete practical demonstrations for PPE, equipment startup/shutdown, interlocks, waste handling, labeling, sample custody, and emergency response.
- Reproduce one approved baseline measurement or analysis using existing reference material.
- Submit a written hazard analysis and experimental plan before beginning any new process.
- Hold a 30-minute mentor meeting to confirm expectations, schedule, communication methods, learning goals, and escalation routes.

### Days 8–30

- Perform baseline tasks under direct supervision.
- Demonstrate traceable sample labeling and complete notebook entries.
- Commit reviewed analysis code and generate a result directly from immutable raw data.
- Present a short literature briefing that compares at least three methods, identifies uncertainties, and states how the proposed work advances the lab roadmap.
- Complete a formal 30-day check-in; access remains provisional until the PI or designee records satisfactory progress.

### Days 31–90

- Progress from supervised to independent authorization only through documented qualification.
- Complete one reproducibility exercise in which another lab member follows the assistant’s documentation.
- Present results with controls, failures, excluded data, uncertainty, and next-step criteria.
- Complete 60- and 90-day reviews covering safety, technical progress, documentation, teamwork, research integrity, and development goals.

## Safety system

### Stop-work authority

Every lab member has both the authority and obligation to stop or decline work when conditions appear unsafe, unauthorized, undocumented, or materially different from the approved procedure. No retaliation is permitted for a good-faith safety report, refusal to bypass an interlock, request for supervision, or report of an incident or near miss.

Work must stop immediately upon loss of ventilation, alarm activation, abnormal pressure or temperature, unexpected reaction, suspected exposure, broken containment, damaged wiring, missing guard or interlock, unlabeled material, conflicting procedure, unapproved recipe change, or uncertainty about waste handling.

### General controls

Before work begins, the assistant must identify materials, quantities, process conditions, routes of exposure, energy sources, failure modes, waste products, required controls, and emergency actions. OSHA laboratory guidance prioritizes hazard evaluation and the selection of engineering controls, administrative controls, and PPE before operations begin.[^20][^21]

Required minimum behaviors include:

- Read the current SOP and Safety Data Sheet before use.
- Use the smallest practical quantity and least hazardous feasible process.
- Verify hood, enclosure, gas-monitor, interlock, exhaust, and emergency equipment status.
- Wear task-specific PPE; ordinary cleanroom garments do not automatically provide chemical protection.
- Label every container, sample, wafer box, syringe, bottle, waste vessel, and temporary process vessel with contents, hazards, owner, and date as required by institutional policy.
- Never defeat interlocks, work around a lockout/tagout, modify gas or electrical systems, or perform unapproved maintenance.
- Never work alone on a procedure designated as buddy-required or outside approved hours.
- Report injuries, suspected exposures, spills, equipment damage, process excursions, and near misses immediately.

### Nanomaterials

Dry, easily dispersed nanomaterials warrant more stringent controls because inhalation risk can be greater than for material embedded in a solid or suspended in liquid. Work that could aerosolize engineered nanoparticles must use an approved enclosure or local exhaust system, and dispersible nanomaterials should remain in closed containers whenever possible.[^21][^20]

For nanopowders and aerosol-generating tasks:

- Use an approved fume hood, HEPA-filtered enclosure, glovebox, or other EHS-approved containment.
- Do not dry sweep or use compressed air; use approved wet wiping or a HEPA-filtered vacuum.[^22][^23]
- Use gloves, protective clothing, and eye protection selected by the hazard assessment; double gloving may be required for dry powders or high-transfer tasks.[^24][^22]
- Do not rely on a respirator unless the institution’s respiratory-protection program has evaluated, medically cleared, fit-tested, and authorized the user.
- Treat unknown nanomaterial toxicity conservatively and assess precursors, by-products, and cleaning agents—not only the final nanomaterial.

### Semiconductor-process hazards

The following require separate written SOPs and hands-on qualification:

- **Hydrofluoric acid and fluoride sources:** HF use requires explicit pre-approval, compatible containment and PPE, an approved hood, and immediate emergency response; it can penetrate tissue and cause systemic toxicity. The facility-specific HF SOP—not this document—must specify first aid, emergency supplies, exposure response, spill response, and medical escalation.[^25]
- **Pyrophoric, toxic, corrosive, or flammable gases:** Only authorized users may operate gas delivery or process systems. Gas cabinets, monitoring, ventilation, automatic shutoff, and emergency power are facility controls and must not be bypassed.[^26]
- **High voltage, RF, and capacitors:** De-energize, verify zero energy, discharge stored energy, use guarding and lockout/tagout, and restrict internal servicing to designated personnel.
- **Vacuum and pressure:** Inspect rated components, shields, viewports, seals, and relief paths; never vent, open, or service a system contrary to the equipment SOP.
- **Lasers and intense optical sources:** Use wavelength-appropriate controls, eyewear, beam enclosures, signage, and institutional laser authorization.
- **Cryogens:** Address oxygen displacement, pressure buildup, cold burns, transport, and compatible PPE; do not enter an alarmed oxygen-deficient area.
- **Furnaces and hot processes:** Control burns, fire, reactive atmospheres, hot-zone labeling, and cooling time.
- **Mechanical fabrication:** Use guards, approved tooling, training, restraints, and eye/face protection; loose clothing, jewelry, and unsecured hair are prohibited near rotating equipment.

### Incident response

1. Protect life: stop work, warn others, move to safety, activate alarms, and call emergency services when indicated.
2. Use an eyewash or safety shower immediately for a relevant exposure; do not delay flushing to complete paperwork or locate a supervisor.
3. Do not clean an unknown, highly hazardous, reactive, airborne, or uncontrolled spill unless specifically trained, equipped, and authorized.
4. Notify the facility manager, mentor, PI, and EHS through institutional channels.
5. Preserve relevant logs, samples, instrument status, and records without re-entering an unsafe area.
6. File the required incident or near-miss report before resuming work.
7. Resume only after the responsible authority closes corrective actions and reauthorizes the task.

## Research records and reproducibility

### Required research record

All work must be recorded contemporaneously in the approved electronic or bound laboratory notebook. A complete entry includes:

- Objective, hypothesis, and decision criterion.
- Date, time, researcher, project, sample and wafer identifiers.
- Exact material source, lot, concentration, preparation, and expiration where relevant.
- Equipment identifier, recipe name and version, calibration status, software/firmware version, probe configuration, and environmental conditions.
- Actual process parameters and deviations—not merely intended parameters.
- Raw-data location, file names, checksums or immutable identifiers where available.
- Controls, replicates, failed runs, anomalies, excluded points, and reasons for exclusions.
- Analysis code commit, environment, dependencies, configuration, and output location.
- Interpretation separated clearly from observation.
- Next action and approval required.

NIH guidance emphasizes that original records should be stored in protected electronic formats, that methods should permit independent replication, and that essential data should be preserved or shared as policy permits. NIH data-management guidance also treats validation, organization, protection, maintenance, accessibility, reliability, and quality as integral to rigor and research integrity.[^27][^11]

### Data rules

- Raw data are immutable. Corrections create a new version; they do not overwrite or silently replace the original.
- Data must be saved directly to approved institutional storage or transferred there by the end of the work session.
- Local instrument computers, USB drives, personal cloud storage, personal email, and messaging applications are not authoritative repositories.
- File and folder names must follow the project convention: `Project_Sample_ProcessOrTest_YYYYMMDD_Run###`.
- Every figure must be reproducible from an identified raw dataset and version-controlled analysis.
- Manual spreadsheet edits that affect results must be logged or replaced by scripted transformations whenever practical.
- Negative results and failed devices must not be deleted to improve apparent yield.
- Exclusions, outlier rules, smoothing, baseline correction, normalization, and image processing must be declared and technically justified.
- AI-assisted code or text must be reviewed by a responsible researcher, comply with confidentiality rules, and never receive proprietary, controlled, unpublished, or personally identifiable information through an unapproved service.

### Code standards

- Use the lab’s version-control system and project repository.
- Keep secrets, passwords, licensed process-design kits, and proprietary models out of ordinary repositories.
- Include a README, environment specification, data dictionary, units, test case, and command or notebook that reproduces each released result.
- Use code review for analysis affecting a publication, sponsor milestone, patent disclosure, or major design decision.
- Tag the exact release used for each figure, table, and tape-out.

### Samples and chain of custody

Each sample or wafer must have a unique, nonrecycled identifier linked to origin, ownership or agreement, process history, storage location, hazards, and disposition. Samples may not be removed, shipped, transferred to another group, destructively tested, or discarded without authorization and any required material-transfer, export, sponsor, or waste approval.

## Research integrity

Research misconduct includes fabrication, falsification, and plagiarism in proposing, performing, reviewing, or reporting research; honest error and differences of opinion are not included in that federal definition. The assistant must never invent a measurement, alter a device curve to hide inconvenient behavior, omit failed runs without disclosure, relabel a sample, manipulate an image deceptively, claim another person’s work, or present preliminary output as validated.[^28][^29]

Good-faith concerns should be reported to the mentor, PI, institutional research-integrity officer, ombuds office, or another approved channel. A person should bypass the ordinary supervisory chain when the supervisor is implicated, a conflict exists, safety is urgent, or retaliation is feared.

## Authorship and credit

Authorship is based on substantive intellectual and accountable contributions, not seniority, routine task completion, time in the lab, or funding alone. The project team will discuss expected contributions at project start, revisit them at major milestones, and finalize them before submission.

The lab will use the CRediT taxonomy to record roles such as conceptualization, methodology, software, validation, investigation, data curation, visualization, supervision, and writing. CRediT improves transparency but does not itself define who qualifies as an author.[^30][^31]

Every listed author must review the relevant manuscript, approve the submitted version, disclose conflicts, and accept responsibility appropriate to the contribution. Contributors who do not meet the applicable journal or institutional authorship standard will be acknowledged when permitted. Disputes proceed from project discussion to PI review and then to the institution’s designated mediation or integrity process.

## Intellectual property and disclosure

Ownership of inventions, mask layouts, circuit designs, software, data, samples, notebooks, and other work products is determined by applicable law, institutional policy, appointment status, sponsor terms, and signed agreements. This onboarding document does **not** independently transfer rights beyond those controlling authorities.

Research assistants must:

- Promptly report potentially patentable inventions through the institution’s approved process before public disclosure.
- Avoid conference abstracts, theses, posters, preprints, repositories, social media, public code releases, or external presentations until the PI and appropriate institutional office complete sponsor, patent, security, and compliance review.
- Preserve publication freedom whenever institutional policy permits; a review for confidential information, patent filing, sponsor obligations, or export control is not permission for indefinite suppression of results.
- Use third-party code, data, process kits, foundry files, images, and designs only under compatible licenses and agreements.
- Return all institutional records, devices, credentials, samples, and equipment at offboarding.

## Confidentiality and cybersecurity

Assistants may encounter unpublished results, sponsor information, foundry process-design kits, layout files, device models, restricted technical data, patent drafts, peer-review material, personnel information, or collaborator data. Access is need-to-know and least-privilege.

The assistant shall not:

- Share credentials or permit another person to use an access badge.
- Upload restricted or unpublished material to personal storage, public repositories, or unapproved generative-AI services.
- Photograph, screen-capture, copy, download, or transmit restricted foundry, sponsor, or collaborator material except as authorized.
- Connect unapproved computers, removable media, wireless devices, or instruments to protected networks.
- Discuss protected projects in public locations or with unauthorized lab members.

Suspected phishing, credential loss, malware, misdirected email, unauthorized access, or data exposure must be reported immediately through institutional cybersecurity procedures.

## Export control and research security

Semiconductor equipment, advanced computing hardware, integrated-circuit designs, software, process recipes, and technical data can raise export-control concerns. Export laws may govern physical shipments, electronic transfers, training, or release of controlled technology to a foreign national in the United States; a fundamental-research exclusion for openly published results does not automatically exempt controlled equipment or technology used during the work.[^32][^33]

Accordingly:

- No assistant may ship, hand-carry, remotely transmit, externally share, or provide access to hardware, samples, software, source code, layouts, process-design kits, recipes, technical data, or controlled equipment without required review.
- International collaborations, foreign visitors, remote access from abroad, travel with devices, and changes in sponsor or project scope must be disclosed to the PI and export-control office before the activity.
- A Technology Control Plan, access restriction, license, screening, or other safeguard must be followed exactly when imposed.
- Nationality or citizenship is never to be used informally by lab members to make access decisions; the institution’s export-control office makes determinations under law and policy.
- All outside appointments, affiliations, funding, gifts, in-kind resources, conflicts of interest, and conflicts of commitment must be disclosed through institutional systems.

University export-control programs specifically flag advanced chips, semiconductor manufacturing, integrated circuits, supercomputers, and related technical activity for review under evolving rules.[^33][^34]

## Communication and work standards

### Weekly cadence

Each assistant will normally complete:

- A weekly written update: objective, work completed, evidence, problems, safety or compliance issues, next steps, and decisions needed.
- A mentor meeting at an agreed frequency, usually weekly for new assistants.
- A current task board or project plan.
- A notebook and repository review at least monthly.
- A research presentation at least once per academic term or project phase.

### Performance criteria

Performance is evaluated on:

1. Safety and compliance.
2. Accuracy and integrity of records.
3. Technical competence and growth.
4. Reproducibility and quality control.
5. Progress against agreed deliverables.
6. Communication, reliability, and teamwork.
7. Care of facilities, instruments, samples, and shared resources.
8. Respectful conduct and contribution to an inclusive learning environment.

Publication count and “successful” experiments are not standalone measures. Promptly reporting a failed process, uncertain result, or safety problem is positive professional conduct.

### Mentoring commitment

The lab will provide clear expectations, task-appropriate supervision, access to required training, timely feedback, reasonable opportunities to learn, and fair consideration for credit. Assistants may request clarification, a different explanation, additional training, or review of an unsafe or unrealistic assignment without penalty.

## Corrective action

Corrective action is proportional to risk, intent, recurrence, and institutional requirements. It may include coaching, retraining, increased supervision, restricted access, written improvement expectations, suspension from a process or facility, reassignment, referral to an institutional office, or termination of lab participation.

Immediate suspension may occur for deliberate interlock bypass, unauthorized hazardous work, falsification or destruction of records, credential sharing, unauthorized disclosure, harassment, violence, theft, retaliation, or conduct creating imminent risk. Institutional due-process, student, employment, union, nondiscrimination, disability, whistleblower, and grievance protections remain controlling.

## Offboarding

Before the final day, the assistant must:

- Bring notebooks, repositories, metadata, documentation, and sample inventories current.
- Transfer ownership or administrative control of institutional files and repositories.
- Provide a status memo listing completed work, unresolved problems, hazards, samples, equipment issues, analysis state, and recommended next steps.
- Return keys, badges, devices, media, tools, samples, documents, and other property.
- Remove personal data from institutional devices without deleting research records.
- Revoke or transfer accounts, tokens, remote access, mailing lists, and instrument permissions.
- Complete invention, authorship, sponsor, data-sharing, material-transfer, and export-control review where applicable.
- Attend an exit meeting and sign the offboarding checklist.

Confidentiality, research-record preservation, intellectual-property, security, and sponsor obligations that law or controlling agreements make continuing remain in effect after departure.

# Research Assistant Agreement

## Parties and appointment

This Research Assistant Onboarding and Participation Agreement (“Agreement”) is between the **MICRO Lab**, operating under its host institution (“Institution”), and the undersigned research assistant (“Assistant”). It governs participation in MICRO Lab activities from the effective date until the Assistant’s access or appointment ends.

**Assistant name:** ____________________________________  
**Institutional ID:** ___________________________________  
**Role/classification:** _________________________________  
**PI:** ________________________________________________  
**Day-to-day mentor:** __________________________________  
**Project:** ____________________________________________  
**Start date:** _______________ **Expected end date:** _______________  
**Expected weekly effort:** ______________________________  
**Appointment basis:** Paid employment / academic credit / fellowship / volunteer / visiting appointment / other institution-approved category

## Agreement terms

### 1. Purpose and controlling authority

The Assistant is joining the lab for research, education, or technical work within the approved appointment. Institution policies, law, funding terms, facility rules, union agreements, and separately signed contracts supersede this Agreement. This Agreement does not guarantee employment, compensation, authorship, a degree outcome, a patent interest, continued access, or a particular project result.

### 2. Scope of authorized work

The Assistant will perform only tasks assigned by the PI or designated mentor and only within documented authorization. The Assistant will not independently change materials, concentrations, dimensions, temperatures, pressures, voltages, gas flows, recipes, layouts, software permissions, or safety controls when the change could affect hazard, equipment, data validity, sponsor terms, security, or export status.

### 3. Training condition

Access is conditional on completion and maintenance of all required institutional and task-specific training. Training completion alone does not authorize equipment use; practical qualification and recorded approval are also required. The Assistant will disclose when training has expired, when a procedure is unfamiliar, or when supervision is needed.

### 4. Safety obligations

The Assistant agrees to follow the chemical hygiene plan, EHS requirements, facility rules, SOPs, hazard assessments, PPE requirements, waste procedures, buddy rules, and emergency instructions. The Assistant will stop work and notify the appropriate person when a condition is unsafe, unexpected, unauthorized, or outside the SOP. The Assistant will not retaliate against another person for a good-faith safety action.

### 5. Prohibited activities

Without written authorization, the Assistant shall not:

- Work with HF, pyrophoric or toxic gases, energetic materials, dispersible nanopowders, high voltage, open lasers, pressure systems, cryogens, radiation, or other designated high-hazard processes.
- Work alone or after hours where prohibited.
- Disable alarms, guards, interlocks, ventilation, monitoring, access controls, or lockout/tagout.
- Modify, repair, open, or service facility equipment.
- Use another person’s credentials, badge, reservations, samples, chemicals, or files.
- Bring food, beverages, cosmetics, or prohibited personal items into controlled laboratory areas.
- Remove materials, data, equipment, or records from approved custody.

### 6. Incident reporting

The Assistant will immediately report injuries, suspected exposures, spills, releases, fires, alarms, damaged equipment, lost samples, data loss, unauthorized access, and near misses. Reporting must occur even if no injury or visible damage is apparent. The Assistant will cooperate honestly with response and review and will not alter relevant records.

### 7. Research records

The Assistant will create timely, accurate, complete, and legible records sufficient for another qualified researcher to understand and reproduce the work. Original data will be preserved; changes, exclusions, and reanalysis will be traceable. The Assistant will use approved repositories and naming conventions and will not delete, fabricate, selectively conceal, or overwrite research records.

### 8. Data, code, designs, and samples

Custody, ownership, access, retention, and sharing are determined by Institution policy and governing agreements. The Assistant may access project materials only for authorized purposes and may not copy, download, upload, release, ship, discard, or transfer them without approval. All project code must be committed to the designated repository, and all samples must remain traceable through the sample-management system.

### 9. Research integrity

The Assistant will not fabricate, falsify, plagiarize, misrepresent, or knowingly permit inaccurate reporting. Errors must be corrected transparently. Suspected misconduct may be reported through the PI or institutional channels, and the Assistant may use an independent channel when a conflict exists.

### 10. Analysis and publication

The Assistant will disclose processing choices, failed runs, exclusions, uncertainty, limitations, and conflicting evidence. The Assistant may not submit, present, post, publish, or externally discuss lab work without the required internal and institutional review. Review may address accuracy, coauthor approval, sponsor obligations, intellectual property, confidentiality, privacy, security, and export control.

### 11. Credit and authorship

Credit will reflect documented contributions and applicable journal and Institution standards. Authorship is not promised in advance. The lab will discuss anticipated contributions, use CRediT roles for transparency, and revisit authorship as work evolves. The Assistant will not accept authorship without reviewing and approving the work and accepting appropriate accountability.

### 12. Intellectual property

The Assistant will comply with the Institution’s intellectual-property and invention-disclosure policies and any controlling appointment or sponsor agreement. Potential inventions will be reported before public disclosure. Nothing in this Agreement creates an ownership right or assignment beyond controlling law and policy.

### 13. Confidentiality

The Assistant will protect unpublished, proprietary, sponsor, foundry, collaborator, peer-review, patent, personnel, security-sensitive, and access-controlled information. The Assistant will use such information only for authorized lab work and will not disclose it to unauthorized persons. If a separate nondisclosure agreement applies, that agreement controls its defined information.

### 14. Cybersecurity

The Assistant will use approved accounts, devices, networks, storage, encryption, multifactor authentication, and software. Credentials may not be shared. Suspected loss, phishing, malware, compromise, or mistaken disclosure will be reported immediately. Restricted information may not be entered into an unapproved cloud or AI system.

### 15. Export control and research security

The Assistant will complete required disclosures and training and will not export, re-export, release, transmit, ship, hand-carry, or provide foreign or remote access to controlled items or technology without institutional authorization. The Assistant will notify the PI and export-control office before international travel, collaboration, visitor access, foreign shipment, or overseas remote work involving lab resources.

### 16. Conflicts and outside activities

The Assistant will accurately disclose outside appointments, affiliations, consulting, funding, gifts, sponsored travel, in-kind support, and personal or financial conflicts as required. Lab purchasing, vendor selection, and research decisions must not be used for undisclosed personal benefit.

### 17. Conduct and inclusion

The Assistant will follow institutional nondiscrimination, anti-harassment, accessibility, violence-prevention, and professional-conduct policies. Bullying, harassment, intimidation, retaliation, sabotage, and discriminatory conduct are prohibited. Scientific disagreement must address evidence and methods rather than personal characteristics.

### 18. Schedule and communication

The Assistant will follow the agreed schedule, communicate absences or delays, attend required meetings, and provide progress updates. Academic and accessibility accommodations will be handled through appropriate institutional processes. Hazardous experiments must not be rushed or performed without required staffing because of a deadline.

### 19. Equipment and purchasing

Lab equipment, purchasing systems, fabrication accounts, software licenses, and supplies are for authorized institutional purposes. The Assistant will record use accurately, avoid waste, report damage, and obtain approval before purchases, fabrication orders, equipment reservations, or external services.

### 20. Monitoring and review

The PI or designee may review notebooks, repositories, access logs, equipment logs, reservations, training records, samples, and work products as permitted by policy. The Assistant will participate in 30-, 60-, and 90-day reviews and subsequent periodic reviews.

### 21. Access restriction or separation

Access may be limited or suspended for safety, compliance, security, training, equipment, performance, funding, project, or facility reasons, subject to controlling institutional protections. Upon separation, the Assistant will complete offboarding and preserve institutional research records.

### 22. Questions and acknowledgement

The Assistant confirms having had an opportunity to ask questions and agrees to seek clarification rather than guess when a procedure, hazard, authorization, or policy is unclear. The Assistant acknowledges that safe and accurate reporting takes priority over speed, apparent success, or avoiding embarrassment.

## Initial project authorization

| Category | Approved scope | Level | Approver initials/date |
|---|---|---:|---|
| Laboratory/cleanroom areas |  |  |  |
| Wet chemistry |  |  |  |
| Nanomaterial handling |  |  |  |
| Deposition/growth |  |  |  |
| Lithography |  |  |  |
| Etch/clean |  |  |  |
| Metrology/microscopy |  |  |  |
| Electrical/RF testing |  |  |  |
| Packaging/assembly |  |  |  |
| Computing/data repositories |  |  |  |
| Controlled/proprietary data |  |  |  |
| After-hours or lone work |  |  |  |

Blank entries mean **not authorized**.

## Required signatures

By signing, each party acknowledges the expectations described above. Signatures do not waive rights provided by law or institutional policy and do not authorize work for which required training or approval is absent.

**Research Assistant**  
Name: ________________________________________________  
Signature: _____________________________________________  
Date: __________________________________________________

**Day-to-Day Mentor**  
Name: ________________________________________________  
Signature: _____________________________________________  
Date: __________________________________________________

**Principal Investigator**  
Name: ________________________________________________  
Signature: _____________________________________________  
Date: __________________________________________________

**Lab/Cleanroom Manager or Safety Designee**  
Name: ________________________________________________  
Signature: _____________________________________________  
Date: __________________________________________________

# Operational forms

## Onboarding checklist

### Administrative

- [ ] Appointment and classification approved.
- [ ] Start/end dates and weekly effort documented.
- [ ] Compensation, credit, or volunteer status documented by the Institution.
- [ ] Emergency contact and accessibility process provided.
- [ ] PI, mentor, manager, safety lead, and data steward assigned.
- [ ] Project charter approved.
- [ ] Agreement signed.

### Training

- [ ] Responsible and Ethical Conduct of Research.
- [ ] Research security and export control.
- [ ] Cybersecurity and data classification.
- [ ] Chemical hygiene and hazardous waste.
- [ ] Cleanroom orientation and gowning.
- [ ] Nanomaterial safety.
- [ ] Equipment-specific practical qualifications.
- [ ] HF, gas, laser, electrical, cryogenic, radiation, machine-shop, or other specialized modules as applicable.
- [ ] Emergency action and incident reporting.

### Research systems

- [ ] Institutional storage access.
- [ ] Electronic notebook created.
- [ ] Repository access and multifactor authentication.
- [ ] File naming and sample identifiers reviewed.
- [ ] Raw-data transfer verified.
- [ ] Baseline dataset reproduced.
- [ ] First literature briefing completed.

### Review gates

- [ ] Day 1 orientation.
- [ ] Week 1 practical review.
- [ ] 30-day review.
- [ ] 60-day review.
- [ ] 90-day qualification decision.

## Project charter

**Project title:**  
**Scientific question:**  
**Why it matters to the MICRO roadmap:**  
**Primary hypothesis:**  
**Device/material/system under study:**  
**Baseline and control:**  
**Independent variables:**  
**Primary outcomes and units:**  
**Acceptance/decision criteria:**  
**Required sample size or replicate logic:**  
**Known confounders and failure modes:**  
**Facilities and equipment:**  
**Hazards and required SOPs:**  
**Data and code locations:**  
**Confidentiality/export/sponsor classification:**  
**Milestones and dates:**  
**Expected assistant contributions/CRediT roles:**  
**PI approval/date:**

## Pre-experiment hazard analysis

**Procedure and SOP version:**  
**Materials and quantities:**  
**Hazardous properties and exposure routes:**  
**Energy sources:**  
**Normal operating limits:**  
**Credible failure modes:**  
**Engineering controls:**  
**Administrative controls:**  
**PPE:**  
**Waste streams:**  
**Spill/exposure response:**  
**Conditions requiring immediate shutdown:**  
**Lone-work/buddy classification:**  
**Researcher signature/date:**  
**Supervisor approval/date:**

## Weekly update

**Week ending:**  
**Objective:**  
**Completed work:**  
**Evidence and links:**  
**Unexpected results or failures:**  
**Safety, compliance, equipment, or data concerns:**  
**Interpretation with uncertainty:**  
**Next week’s tasks:**  
**Decisions or help needed:**

## Qualification record

**Equipment/process:**  
**SOP/recipe version:**  
**Observed demonstrations completed:**  
**Supervised runs completed:**  
**Practical skills evaluated:**  
**Emergency response evaluated:**  
**Permitted materials/recipes:**  
**Prohibited conditions:**  
**Authorization level:**  
**Expiration or requalification date:**  
**Trainer signature/date:**  
**Manager approval/date:**

## Incident or near-miss record

**Date/time/location:**  
**People involved or exposed:**  
**Immediate actions:**  
**Emergency/EHS notifications:**  
**Materials, equipment, or data involved:**  
**What occurred:**  
**Potential consequences:**  
**Preserved records/logs:**  
**Contributing conditions:**  
**Corrective actions and owners:**  
**Approval required before restart:**  
**Closure authority/date:**

## Offboarding checklist

- [ ] Final project-status memo delivered.
- [ ] Notebooks and metadata complete.
- [ ] Raw data and code transferred and verified.
- [ ] Repositories transferred to institutional owners.
- [ ] Samples inventoried, labeled, and transferred or disposed of properly.
- [ ] Equipment status and unresolved maintenance documented.
- [ ] Invention and publication review completed.
- [ ] Keys, badge, devices, media, tools, and documents returned.
- [ ] Facility, repository, mailing-list, VPN, cloud, and instrument access removed.
- [ ] Confidential/proprietary copies on personal systems removed as directed and permitted.
- [ ] Authorship and continuing contribution expectations documented.
- [ ] Exit meeting completed.

**Assistant signature/date:**  
**Mentor signature/date:**  
**PI signature/date:**  
**Manager/data-steward signature/date:**

## Adoption checklist for leadership

Before issuing this document, lab leadership should:

- Replace generic role names with the Institution’s official reporting offices and emergency contacts.
- Reconcile all terms with HR, student, volunteer, union, privacy, accessibility, nondiscrimination, intellectual-property, and legal requirements.
- Attach facility-specific SOPs rather than relying on general safety language.
- Obtain EHS approval for nanomaterials, HF, gases, lasers, radiation, electrical work, cryogens, pressure/vacuum systems, and emergency procedures.
- Obtain export-control classification for relevant equipment, software, foundry materials, technical data, collaborators, travel, and visitors.
- Align data retention, repository, cybersecurity, sponsor, and open-science requirements.
- Define who may grant, suspend, and restore each authorization level.
- Review the document annually and after any serious incident, major facility change, sponsor change, or regulatory update.

---

## References

1. [Heterogeneous and Monolithic 3D Integration of III-V-Based Radio Frequency Devices on Si CMOS Circuits - PubMed](https://pubmed.ncbi.nlm.nih.gov/35437991/) - Here we report heterogeneous and monolithic three-dimensional (3D) analog/RF-digital mixed-signal in...

2. [Three-dimensional integration of two-dimensional field- ...](https://pubmed.ncbi.nlm.nih.gov/38200300/) - Here we demonstrate (1) wafer-scale and monolithic two-tier 3D integration based on MoS~2~ with more...

3. [High-performance, power-efficient three-dimensional system-in-package designs with universal chiplet interconnect express - Nature Electronics](https://www.nature.com/articles/s41928-024-01126-y) - We have reported UCIe-3D, a power-performance efficient and cost-effective method for constructing S...

4. [Build it up](https://www.nature.com/articles/s41928-024-01206-z) - Advanced packaging technologies allow multiple chips (or chiplets) to be combined into packages.

5. [An analog-AI chip for energy-efficient speech recognition and ...](https://pmc.ncbi.nlm.nih.gov/articles/PMC10447234/) - Here we present an analog-AI chip that combines 35 million phase-change memory devices across 34 til...

6. [An analog-AI chip for energy-efficient speech recognition ...](https://www.nature.com/articles/s41586-023-06337-5) - by S Ambrogio · 2023 · Cited by 349 — In this paper, we present experimental results using a 14-nm i...

7. [Promises and prospects of two-dimensional transistors - PubMed](https://pubmed.ncbi.nlm.nih.gov/33658691/) - # Promises and prospects of two-dimensional transistors
...
2021 Mar;591(7848):43-53.

8. [Transistor engineering based on 2D materials in the post-silicon era - Nature Reviews Electrical Engineering](https://www.nature.com/articles/s44287-024-00045-6) - Two-dimensional materials (2DMs) with atomic scale thicknesses and non-dangling bonds interface enab...

9. [A full spectrum of computing-in-memory technologies - Nature Electronics](https://www.nature.com/articles/s41928-023-01053-4) - *Nat Electron* **6**, 823–835 (2023).

10. [Fabrication of high aspect ratio, non-line-of-sight vias in silicon carbide by a two-photon absorption method - Scientific Reports](https://www.nature.com/articles/s41598-024-52672-6) - Here, we demonstrate the fabrication of high-aspect ratio, non-line-of-sight TWVs in silicon carbide...

11. [Conduct of Research](https://oir.nih.gov/system/files/media/file/2026-09/guidelines-conduct_research.pdf) - Sufficiently detailed information must be provided in the Materials and Methods sections of research...

12. [Rigor, Reproducibility, and Transparency in Shared ...](https://pmc.ncbi.nlm.nih.gov/articles/PMC10001929/) - 8. **Assure** that both the documentation and the original, unprocessed data are properly stored in ...

13. [1](https://www.nature.com/articles/s41598-021-85968-y.pdf) - on the electrical properties of  MoS2
field‑effect transistors

14. [Ge 0.95 Sn 0.05 Gate-All-Around p-Channel Metal-Oxide ... - PubMed](https://pubmed.ncbi.nlm.nih.gov/34105972/) - # Ge 0.95 Sn 0.05 Gate-All-Around p-Channel Metal-Oxide-Semiconductor Field-Effect Transistors with ...

15. [Toward attojoule switching energy in logic transistors - PubMed](https://pubmed.ncbi.nlm.nih.gov/36395210/) - # Toward attojoule switching energy in logic transistors
...
2022 Nov 18;378(6621):733-740.

16. [Fully hardware-implemented memristor convolutional neural network - Nature](https://www.nature.com/articles/s41586-020-1942-4) - *et al.* Fully hardware-implemented memristor convolutional neural network.

17. [Low-power 2D gate-all-around logics via epitaxial monolithic 3D integration - Nature Materials](https://www.nature.com/articles/s41563-025-02117-w) - Here we report a wafer-scale multi-layer-stacked single-crystalline 2D GAA configuration achieved wi...

18. [Responsible and Ethical Conduct of Research - Policies | NSF ...](https://www.nsf.gov/policies/responsible-research-conduct) - The U.S. National Science Foundation (NSF) requires institutions to have a plan to provide appropria...

19. [Research Security Training](https://www.nsf.gov/research-security/training) - On July 10, 2025, NSF issued an Important Notice that provided updates to NSF research security poli...

20. [Occupational Exposure to Hazardous Chemicals in ... - OSHA](https://www.osha.gov/laws-regs/federalregister/2013-01-22) - to nanomaterials including inhalation, ingestion, injection, and
...
Avoid handling

21. [1910.1450 App A - National Research Council Recommendations ...](https://www.osha.gov/laws-regs/regulations/standardnumber/1910/1910.1450AppA) - Avoid handling nanomaterials in the open air in a free-particle state.

22. [Nanomaterials | Environment, Health and Safety - Cornell EHS](https://ehs.cornell.edu/research-safety/chemical-safety/specific-chemical-hazards/nanomaterials) - Cornell Environment, Health and Safety (EHS) applies a precautionary, risk-based approach to nanomat...

23. [Working Safely with Nanomaterials](https://www.osha.gov/sites/default/files/publications/OSHA_FS-3634.pdf) - OSHA recommends that worker exposure to respirable carbon nanotubes and carbon nanofibers not exceed...

24. [Nanomaterials | Environmental Health & Safety (EHS)](https://ehs.utexas.edu/working-safely/chemical-safety/nanomaterials) - According to OSHA, laboratory personnel must be informed of the risks associated with workplace haza...

25. [Hydrofluoric Acid (HF)](https://ehs.ucr.edu/media/5921/download?attachment) - Nalgene/polypropylene secondary containment.
...
Use a fume hood to mitigate exposure to HF.

26. [Safety - NC State NNF](https://nnf.ncsu.edu/safety/) - Safeguards include gas monitoring systems, fast response smoke detection systems, standardized gas h...

27. [Data Management | Grants & Funding](https://grants.nih.gov/policy-and-compliance/policy-topics/sharing-policies/dms/data-management) - Data management is the process of validating, organizing, protecting, maintaining, and processing sc...

28. [FAQ's on Research Misconduct and Fraud Concerns Outside ORI's ...](https://ori.hhs.gov/faqs-research-misconduct-and-fraud-concerns-outside-oris-authority) - Plagiarism means the appropriation of another person's ideas, processes, results, or words, without ...

29. [Definition of Research Misconduct](https://ori.hhs.gov/definition-research-misconduct) - Research misconduct means fabrication, falsification, or plagiarism in proposing, performing, or rev...

30. [Extended Description - Contributor Roles Taxonomy (CRediT)](https://credit.niso.org/contributor-roles/) - That is, these roles are not intended to define what constitutes authorship.

31. [CRediT](https://credit.niso.org/) - CRediT is a community-owned taxonomy of 14 contributor roles designed to represent the key types of ...

32. [Export Control Manual | Office of Research](https://www.bu.edu/research/ethics-compliance/research-security/export-control/export-control-manual/) - Shipments and transport of equipment, technology or software outside of the US is ALWAYS subject to ...

33. [Export Control and Compliance](https://www.research.ucsb.edu/export-control/about) - Under revisions to federal export control laws a license may be required for activities involving ad...

34. [UNL | Export Control Guidance (A-Z)](https://research.unl.edu/researchcompliance/activities-subject-to-export-controls/) - This page is intended to provide guidance regarding activities subject to export controls and typica...

