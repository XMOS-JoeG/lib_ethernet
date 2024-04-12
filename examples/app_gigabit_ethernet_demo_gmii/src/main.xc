// Copyright 2015-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include <xs1.h>
#include <platform.h>
#include <stdio.h>
#include "otp_board_info.h"
#include "ethernet.h"
#include "icmp.h"
#include "smi.h"
#include "debug_print.h"

// These ports are for accessing the OTP memory
otp_ports_t otp_ports = on tile[0]: OTP_PORTS_INITIALIZER;

// Tile number used in app note text
rgmii_ports_t rgmii_ports = on tile[1]: RGMII_PORTS_INITIALIZER;

    port     p_smi_mdio  = on tile[1]: XS1_PORT_1M;
    port     p_smi_mdc   = on tile[1]: XS1_PORT_1N;
out port     p_eth_reset  = on tile[1]: XS1_PORT_4A; // Bit 3 is reset_n (active low), other bits unconnected.

//static unsigned char ip_address[4] = {192, 168, 1, 178};
static unsigned char ip_address[4] = {10, 0, 102, 182};

// An enum to manage the array of connections from the ethernet component
// to its clients.
enum eth_clients {
  ETH_TO_ICMP,
  NUM_ETH_CLIENTS
};

enum cfg_clients {
  CFG_TO_ICMP,
  CFG_TO_PHY_DRIVER,
  NUM_CFG_CLIENTS
};

// Check the correct device is present at the phy address specified
// phy_id is the most significant 28 bits of the expected PHY Identifier.
// PHY identifier is found in contents of registers 2 and 3 where register 2 is MS word and register 3 is LS word.
static int check_phy(client interface smi_if smi, int phy_addr, int phy_id)
{
  unsigned phy_id_ms = smi.read_reg(phy_addr, 0x2);
  unsigned phy_id_ls = smi.read_reg(phy_addr, 0x3);
  unsigned phy_id_full = ((phy_id_ms << 16) | phy_id_ls) >> 4; // Most significant 28 bits of PHY identifier
  //debug_printf("phy_id_full is 0x%08X\n", phy_id_full);
  if (phy_id_full == phy_id)
    return 0;
  else
    return 1;
}

[[combinable]]
void vsc8541_phy_driver(client interface smi_if smi,
                        client interface ethernet_cfg_if eth) {
  ethernet_link_state_t link_state = ETHERNET_LINK_DOWN;
  ethernet_speed_t link_speed = LINK_1000_MBPS_FULL_DUPLEX;
  const int phy_reset_delay_ms = 10;
  const int link_poll_period_ms = 1000;
  const int phy_address = 0;
  unsigned reg_read_val, reg_write_val;
  timer tmr;
  int t;
  tmr :> t;
  p_eth_reset <: 0x0;
  delay_milliseconds(phy_reset_delay_ms);
  p_eth_reset <: 0x8; // Reset is on bit 3 of 4 bit port.
  delay_milliseconds(15); // Datasheet says wait 15ms after release of reset before access.
  
  #define VSC8541_PHY_ID 0x0007077 // Most significant 28 bits of PHY Identifier. This incorporates OUI and model number.
  
  debug_printf("Hello World Debug\n");
  
  if (check_phy(smi, phy_address, VSC8541_PHY_ID))
    debug_printf("Did not find expected PHY\n");
  else
    debug_printf("Found expected PHY\n");
  
  while (smi_phy_is_powered_down(smi, phy_address));

  smi_phy_reset(smi, phy_address); // optional?

  #define EXTENDED_REGISTER_PAGE_ADDR  31
  #define VSC8541_WOL_AND_MAC_IF_CTRL_ADDR 27
  #define VSC8541_PAD_EDGE_RATE 2 // Setting +2 works well with 33R series terminator and 50 ohm trace.
  // Set up any relevant registers here - check procedure in datasheet. Things like MAC pad edge rate etc.

  // Read modify Write Wake-on-LAN and MAC Interface control register to set the pad edge rate.
  smi.write_reg(phy_address, EXTENDED_REGISTER_PAGE_ADDR, 2); // Register addresses 16-30 now access extended register space 2.
  reg_read_val = smi.read_reg(phy_address, VSC8541_WOL_AND_MAC_IF_CTRL_ADDR);
  reg_write_val = (reg_read_val & 0xFF1F) | (VSC8541_PAD_EDGE_RATE << 5); // Set MAC interface pad edge rate
  smi.write_reg(phy_address, VSC8541_WOL_AND_MAC_IF_CTRL_ADDR, reg_write_val);
  smi.write_reg(phy_address, EXTENDED_REGISTER_PAGE_ADDR, 0); // Main register access restored.

  smi_configure(smi, phy_address, LINK_1000_MBPS_FULL_DUPLEX, SMI_ENABLE_AUTONEG);

  while (1) {
    select {
    case tmr when timerafter(t) :> t:

      ethernet_link_state_t new_state = smi_get_link_state(smi, phy_address);

      // Poll register 0x1C bits 4:3 to get the current link speed
      if (new_state == ETHERNET_LINK_UP) {
        // FIXME: Remove magic numbers
        link_speed = (ethernet_speed_t)(smi.read_reg(phy_address, 0x1C) >> 3) & 3;
        debug_printf("link_speed = %x\n", link_speed);
      }
      if (new_state != link_state) {
        link_state = new_state;
        eth.set_link_state(0, link_state, link_speed);
        debug_printf("link_state %d\n", link_state);
      }
      t += link_poll_period_ms * XS1_TIMER_KHZ;
      break;
    }
  }
}

int main()
{
  ethernet_cfg_if i_cfg[NUM_CFG_CLIENTS];
  ethernet_rx_if i_rx[NUM_ETH_CLIENTS];
  ethernet_tx_if i_tx[NUM_ETH_CLIENTS];
  streaming chan c_rgmii_cfg;
  smi_if i_smi;

  par {
    on tile[1]: rgmii_ethernet_mac(i_rx, NUM_ETH_CLIENTS,
                                   i_tx, NUM_ETH_CLIENTS,
                                   null, null,
                                   c_rgmii_cfg,
                                   rgmii_ports, 
                                   ETHERNET_DISABLE_SHAPER);
    on tile[1].core[0]: rgmii_ethernet_mac_config(i_cfg, NUM_CFG_CLIENTS, c_rgmii_cfg);
    on tile[1].core[0]: vsc8541_phy_driver(i_smi, i_cfg[CFG_TO_PHY_DRIVER]);
  
    on tile[1]: smi(i_smi, p_smi_mdio, p_smi_mdc);

    on tile[0]: icmp_server(i_cfg[CFG_TO_ICMP],
                            i_rx[ETH_TO_ICMP], i_tx[ETH_TO_ICMP],
                            ip_address, otp_ports);
                           
  }
  return 0;
}
