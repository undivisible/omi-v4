use crate::signals::{
    ActionProposal, ActionRisk, ApprovalDecision, ComputerUseAction, NativeEvent,
};
use std::collections::{HashMap, VecDeque};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const PENDING_PROPOSAL_CAPACITY: usize = 64;
pub(crate) const TERMINAL_PROPOSAL_CAPACITY: usize = 256;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ProposalStatus {
    Pending,
    Approved,
    Rejected,
    Expired,
    Invalidated,
    Executed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ProposalFingerprint {
    pub(crate) uid: String,
    pub(crate) authority_generation: u64,
    pub(crate) parent_request_id: String,
    pub(crate) expires_at_ms: Option<i64>,
    pub(crate) risk: ActionRisk,
    pub(crate) title: String,
    pub(crate) summary: String,
    pub(crate) computer_action: Option<ComputerUseAction>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ProposalRecord {
    pub(crate) fingerprint: ProposalFingerprint,
    pub(crate) status: ProposalStatus,
}

#[derive(Default)]
pub(crate) struct ProposalRegistry {
    pub(crate) pending: HashMap<String, ProposalRecord>,
    pub(crate) terminal: HashMap<String, ProposalRecord>,
    terminal_order: VecDeque<String>,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum ProposalRegistration {
    Registered,
    ExactReplay,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum ProposalDecisionError {
    NotFound,
    WrongAuthority,
    Expired,
    AlreadyDecided,
    Capacity,
    Conflict,
    ExecutionUnavailable,
}

impl ProposalRegistry {
    pub(crate) fn register(
        &mut self,
        uid: &str,
        authority_generation: u64,
        proposal: ActionProposal,
    ) -> Result<ProposalRegistration, ProposalDecisionError> {
        let now_ms = unix_time_ms();
        self.purge_expired(now_ms);
        let fingerprint = ProposalFingerprint {
            uid: uid.to_owned(),
            authority_generation,
            parent_request_id: proposal.request_id.clone(),
            expires_at_ms: proposal.expires_at_ms,
            risk: proposal.risk,
            title: proposal.title.clone(),
            summary: proposal.summary.clone(),
            computer_action: proposal.computer_action.clone(),
        };
        if let Some(existing) = self
            .pending
            .get(&proposal.proposal_id)
            .or_else(|| self.terminal.get(&proposal.proposal_id))
        {
            return if existing.fingerprint == fingerprint {
                Ok(ProposalRegistration::ExactReplay)
            } else {
                Err(ProposalDecisionError::Conflict)
            };
        }
        if self.pending.len() >= PENDING_PROPOSAL_CAPACITY {
            return Err(ProposalDecisionError::Capacity);
        }
        self.pending.insert(
            proposal.proposal_id.clone(),
            ProposalRecord {
                fingerprint,
                status: ProposalStatus::Pending,
            },
        );
        if proposal
            .expires_at_ms
            .is_some_and(|expires| expires <= now_ms)
        {
            self.finish(&proposal.proposal_id, ProposalStatus::Expired);
            return Err(ProposalDecisionError::Expired);
        }
        NativeEvent::ActionProposal(proposal).send();
        Ok(ProposalRegistration::Registered)
    }

    pub(crate) fn decide(
        &mut self,
        proposal_id: &str,
        uid: &str,
        authority_generation: u64,
        decision: ApprovalDecision,
        now_ms: i64,
        computer_use_available: bool,
    ) -> Result<(ProposalRecord, Option<ComputerUseAction>), ProposalDecisionError> {
        self.purge_expired(now_ms);
        if let Some(record) = self.terminal.get(proposal_id) {
            return if record.fingerprint.uid != uid
                || record.fingerprint.authority_generation != authority_generation
            {
                Err(ProposalDecisionError::WrongAuthority)
            } else if record.status == ProposalStatus::Expired {
                Err(ProposalDecisionError::Expired)
            } else {
                Err(ProposalDecisionError::AlreadyDecided)
            };
        }
        let record = self
            .pending
            .get(proposal_id)
            .ok_or(ProposalDecisionError::NotFound)?;
        if record.fingerprint.uid != uid
            || record.fingerprint.authority_generation != authority_generation
        {
            return Err(ProposalDecisionError::WrongAuthority);
        }
        if record
            .fingerprint
            .expires_at_ms
            .is_some_and(|expires| expires <= now_ms)
        {
            self.finish(proposal_id, ProposalStatus::Expired);
            return Err(ProposalDecisionError::Expired);
        }
        let action = match decision {
            ApprovalDecision::ApproveOnce => record.fingerprint.computer_action.clone(),
            ApprovalDecision::Reject => None,
        };
        if action.is_some() && !computer_use_available {
            return Err(ProposalDecisionError::ExecutionUnavailable);
        }
        let status = match (decision, action.is_some()) {
            (ApprovalDecision::ApproveOnce, true) => ProposalStatus::Executed,
            (ApprovalDecision::ApproveOnce, false) => ProposalStatus::Approved,
            (ApprovalDecision::Reject, _) => ProposalStatus::Rejected,
        };
        self.finish(proposal_id, status)
            .map(|record| (record, action))
            .ok_or(ProposalDecisionError::NotFound)
    }

    pub(crate) fn invalidate_parent(&mut self, uid: &str, authority_generation: u64, parent: &str) {
        self.purge_expired(unix_time_ms());
        let ids = self
            .pending
            .iter()
            .filter(|(_, record)| {
                record.fingerprint.uid == uid
                    && record.fingerprint.authority_generation == authority_generation
                    && record.fingerprint.parent_request_id == parent
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in ids {
            self.finish(&id, ProposalStatus::Invalidated);
        }
    }

    pub(crate) fn invalidate_generation(&mut self, uid: &str, authority_generation: u64) {
        let parents = self
            .pending
            .values()
            .filter(|record| {
                record.fingerprint.uid == uid
                    && record.fingerprint.authority_generation == authority_generation
            })
            .map(|record| record.fingerprint.parent_request_id.clone())
            .collect::<Vec<_>>();
        for parent in parents {
            self.invalidate_parent(uid, authority_generation, &parent);
        }
    }

    fn finish(&mut self, proposal_id: &str, status: ProposalStatus) -> Option<ProposalRecord> {
        let mut record = self.pending.remove(proposal_id)?;
        record.status = status;
        self.terminal.insert(proposal_id.to_owned(), record.clone());
        self.terminal_order.push_back(proposal_id.to_owned());
        if self.terminal.len() > TERMINAL_PROPOSAL_CAPACITY
            && let Some(expired) = self.terminal_order.pop_front()
        {
            self.terminal.remove(&expired);
        }
        Some(record)
    }

    fn purge_expired(&mut self, now_ms: i64) {
        let expired = self
            .pending
            .iter()
            .filter(|(_, record)| {
                record
                    .fingerprint
                    .expires_at_ms
                    .is_some_and(|expires| expires <= now_ms)
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in expired {
            self.finish(&id, ProposalStatus::Expired);
        }
    }
}

pub(crate) fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(i64::MAX as u128) as i64
        })
}
