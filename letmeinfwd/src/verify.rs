// -*- coding: utf-8 -*-
//
// Copyright (C) 2024 Michael Büsch <m@bues.ch>
//
// Licensed under the Apache License version 2.0
// or the MIT license, at your option.
// SPDX-License-Identifier: Apache-2.0 OR MIT

//! Rule verification functionality for testing

use anyhow::{self as ah};
use letmein_conf::Config;
use nftables::{
    helper::get_current_ruleset_with_args_async,
    schema::{NfListObject, NfObject},
};

use std::{env, net::IpAddr, process::Command};

/// Verify if a rule exists or is missing in the nftables ruleset
/// 
/// This function is used in tests to verify if a rule exists or not.
/// It returns true if the verification passed, false otherwise.
#[allow(dead_code)]
pub async fn verify_nft_rule(
    _config: &Config,
    addr_str: &str,
    port: u16,
    proto: &str,
    should_exist: bool,
) -> ah::Result<bool> {
    // Check if MOCK_NFTABLES is set, if so, skip actual verification
    if let Ok(mock_value) = env::var("MOCK_NFTABLES") {
        if mock_value == "1" {
            println!("MOCK_NFTABLES=1 detected, skipping nftables rule verification");
            println!("✓ OK: Verification skipped in MOCK_NFTABLES mode for {} port {}/{}", 
                    addr_str, port, proto);
            return Ok(true); // Always succeed in mock mode
        }
    }

    // Parse the IP address
    let addr: IpAddr = match addr_str.parse() {
        Ok(addr) => addr,
        Err(e) => {
            eprintln!("Error parsing IP address {}: {}", addr_str, e);
            return Ok(false);
        }
    };

    // Generate the comment string that identifies the rule
    // Format: "letmein_{addr}-{port}/{proto}"
    let comment = format!("letmein_{}-{}/{}", addr, port, proto);
    
    // Try to handle JSON output environment variable (for debug/logging purposes)
    let json_output = env::var("NFT_JSON_OUTPUT").unwrap_or_else(|_| String::from("0"));
    
    // Debug logging for CI environment detection
    if let Ok(ci) = env::var("CI") {
        eprintln!("\x1b[1;33mCI environment detected (CI={}), using standard nft crate for verification\x1b[0m", ci);
    }
    
    // Use the standard nft crate method for all environments
    let ruleset = match get_current_ruleset_with_args_async(None::<&str>, None::<&str>).await {
        Ok(ruleset) => ruleset,
        Err(e) => {
            eprintln!("\x1b[1;31mError getting nftables ruleset: {}\x1b[0m", e);
            eprintln!("\x1b[1;33mNFT_JSON_OUTPUT is set to: {}\x1b[0m", json_output);
            
            // Try to run nft directly to see what's happening
            eprintln!("\x1b[1;36mTrying direct nft command for diagnostics:\x1b[0m");
            // Execute the nft command with the same arguments
            let output = Command::new("nft").args(["--json", "list", "ruleset"]).output().unwrap();
            eprintln!("\x1b[1;32m==== nft output: ====\x1b[0m\n{}", String::from_utf8_lossy(&output.stdout));
            eprintln!("\x1b[1;31m==== nft stderr: ====\x1b[0m\n{}", String::from_utf8_lossy(&output.stderr));
            
            return Err(e.into());
        }
    };
    
    // Print the ruleset for debugging
    println!("Current nftables ruleset:");
    for obj in ruleset.objects.to_vec().iter() {
        println!("{:?}", obj);
    }
    
    // Check if rule exists by looking for our comment identifier
    let rule_exists = ruleset.objects.to_vec().iter().any(|obj| {
        match obj {
            NfObject::ListObject(NfListObject::Rule(rule)) => {
                // Use debug formatting since Rule doesn't implement Display
                format!("{:?}", rule).contains(&comment)
            },
            _ => false
        }
    });
    
    let result = match should_exist {
        true => {
            if rule_exists {
                println!("✓ OK: Rule found for {} port {}/{}", addr, port, proto);
                true
            } else {
                eprintln!("✗ ERROR: Rule not found for {} port {}/{}", addr, port, proto);
                false
            }
        },
        false => {
            if !rule_exists {
                println!("✓ OK: Rule successfully removed for {} port {}/{}", addr, port, proto);
                true
            } else {
                eprintln!("✗ ERROR: Rule still present for {} port {}/{}", addr, port, proto);
                false
            }
        }
    };
    
    Ok(result)
}
