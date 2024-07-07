// -*- coding: utf-8 -*-
//
// Copyright (C) 2024 Michael Büsch <m@bues.ch>
//
// Licensed under the Apache License version 2.0
// or the MIT license, at your option.
// SPDX-License-Identifier: Apache-2.0 OR MIT

use anyhow::{self as ah, format_err as err, Context as _};
use letmein_fwproto::{FirewallMessage, FirewallOperation, SOCK_FILE};
use std::{net::IpAddr, path::Path};
use tokio::net::UnixStream;

pub struct FirewallClient {
    stream: UnixStream,
}

impl FirewallClient {
    /// Connect to the firewall daemon via Unix socket.
    pub async fn new(rundir: &Path) -> ah::Result<Self> {
        let sock_path = rundir.join("letmeinfwd").join(SOCK_FILE);
        let stream = UnixStream::connect(sock_path)
            .await
            .context("Connect to Unix socket")?;
        Ok(Self { stream })
    }

    /// Send a request to open a firewall `port` for the specified `addr`.
    pub async fn open_port(&mut self, addr: IpAddr, port: u16) -> ah::Result<()> {
        // Send an open-port request to the firewall daemon.
        FirewallMessage::new_open(addr, port)
            .send(&mut self.stream)
            .await
            .context("Send port-open message")?;

        // Receive the open-port reply.
        let Some(msg_reply) = FirewallMessage::recv(&mut self.stream)
            .await
            .context("Receive port-open reply")?
        else {
            return Err(err!("Connection terminated"));
        };

        match msg_reply.operation() {
            FirewallOperation::Ack => Ok(()),
            FirewallOperation::Nack => Err(err!("The firewall rejected the port-open request")),
            FirewallOperation::OpenV4 | FirewallOperation::OpenV6 => {
                Err(err!("Received invalid reply"))
            }
        }
    }
}

// vim: ts=4 sw=4 expandtab
