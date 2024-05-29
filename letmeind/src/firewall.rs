// -*- coding: utf-8 -*-
//
// Copyright (C) 2024 Michael Büsch <m@bues.ch>
//
// Licensed under the Apache License version 2.0
// or the MIT license, at your option.
// SPDX-License-Identifier: Apache-2.0 OR MIT

use crate::ConfigRef;
use anyhow::{self as ah, format_err as err, Context as _};
use nftables::{
    batch::Batch,
    expr::{Expression, NamedExpression, Payload, PayloadField},
    helper::apply_ruleset,
    schema::{Chain, FlushObject, NfCmd, NfListObject, Rule},
    stmt::{Match, Operator, Statement},
    types::NfFamily,
};
use std::{
    collections::HashMap,
    net::IpAddr,
    time::{Duration, Instant},
};

fn statement_match_saddr(addr: IpAddr) -> Statement {
    let protocol = match addr {
        IpAddr::V4(_) => "ip",
        IpAddr::V6(_) => "ip6",
    };
    Statement::Match(Match {
        left: Expression::Named(NamedExpression::Payload(Payload::PayloadField(
            PayloadField {
                protocol: protocol.to_string(),
                field: "saddr".to_string(),
            },
        ))),
        right: Expression::String(addr.to_string()),
        op: Operator::EQ,
    })
}

fn statement_match_dport(port: u16) -> Statement {
    Statement::Match(Match {
        left: Expression::Named(NamedExpression::Payload(Payload::PayloadField(
            PayloadField {
                protocol: "tcp".to_string(),
                field: "dport".to_string(),
            },
        ))),
        right: Expression::Number(port.into()),
        op: Operator::EQ,
    })
}

fn statement_accept() -> Statement {
    Statement::Accept(None)
}

const LEASE_TIMEOUT: Duration = Duration::from_secs(60 * 60);

struct Lease {
    addr: IpAddr,
    port: u16,
    timeout: Instant,
}

impl Lease {
    pub fn new(addr: IpAddr, port: u16) -> Self {
        let timeout = Instant::now() + LEASE_TIMEOUT;
        Self {
            addr,
            port,
            timeout,
        }
    }

    pub fn refresh_timeout(&mut self) {
        self.timeout = Instant::now() + LEASE_TIMEOUT;
    }

    pub fn is_timed_out(&self, now: Instant) -> bool {
        now >= self.timeout
    }

    pub fn gen_rule(&self, family: NfFamily, table: &str, chain_input: &str) -> NfListObject {
        NfListObject::Rule(Rule::new(
            family,
            table.to_string(),
            chain_input.to_string(),
            vec![
                statement_match_saddr(self.addr),
                statement_match_dport(self.port),
                statement_accept(),
            ],
        ))
    }
}

type LeaseId = (IpAddr, u16);

pub struct Firewall {
    leases: HashMap<LeaseId, Lease>,
}

impl Firewall {
    pub async fn new(conf: &ConfigRef<'_>) -> ah::Result<Self> {
        let mut this = Self {
            leases: HashMap::new(),
        };
        this.clear(conf).await.context("Nftables initialization")?;
        Ok(this)
    }

    pub async fn clear(&mut self, conf: &ConfigRef<'_>) -> ah::Result<()> {
        self.leases.clear();
        self.apply_nftables(conf)
    }

    pub async fn maintain(&mut self, conf: &ConfigRef<'_>) -> ah::Result<()> {
        let old_len = self.leases.len();

        let now = Instant::now();
        self.leases.retain(|_, lease| !lease.is_timed_out(now));

        if old_len != self.leases.len() {
            self.apply_nftables(conf)?;
        }
        Ok(())
    }

    pub async fn open_port(
        &mut self,
        conf: &ConfigRef<'_>,
        remote_addr: IpAddr,
        port: u16,
    ) -> ah::Result<()> {
        let id = (remote_addr, port);
        if let Some(lease) = self.leases.get_mut(&id) {
            lease.refresh_timeout();
        } else {
            self.leases.insert(id, Lease::new(remote_addr, port));
            if let Err(e) = self.apply_nftables(conf) {
                self.leases.remove(&id);
                return Err(e);
            }
        }
        Ok(())
    }

    fn apply_nftables(&mut self, conf: &ConfigRef<'_>) -> ah::Result<()> {
        let family = match conf.nft_family() {
            "inet" => NfFamily::INet,
            "ip" => NfFamily::IP,
            "ip6" => NfFamily::IP6,
            fam => {
                return Err(err!("Unknown NFT family: {fam}"));
            }
        };
        let table = conf.nft_table();
        let chain_input = conf.nft_chain_input();

        let chain = Chain::new(
            family,
            table.to_string(),
            chain_input.to_string(),
            None,
            None,
            None,
            None,
            None,
        );

        let mut batch = Batch::new();
        batch.add_cmd(NfCmd::Flush(FlushObject::Chain(chain)));

        for lease in self.leases.values() {
            batch.add(lease.gen_rule(family, table, chain_input));
        }

        let ruleset = batch.to_nftables();
        apply_ruleset(&ruleset, None, None).context("Apply nftables")?;

        println!("Nftables rules applied");
        Ok(())
    }
}

// vim: ts=4 sw=4 expandtab
