// Copyright 2015-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include <xs1.h>
#include "xassert.h"
#include "ethernet.h"
#include "rgmii.h"
#include "rgmii_10_100_master.h"
#include "rgmii_buffering.h"
#include "macaddr_filter_hash.h"
#include "rgmii_consts.h"
#include "debug_print.h"

// Defines for SETPADCTRL

#define DR_STR_2mA     0
#define DR_STR_4mA     1
#define DR_STR_8mA     2
#define DR_STR_12mA    3

#define PORT_PAD_CTL_SMT    0           // Schmitt off
#define PORT_PAD_CTL_SR     1           // Fast slew
#define PORT_PAD_CTL_DR_STR DR_STR_8mA  // 8mA drive
#define PORT_PAD_CTL_REN    1           // Receiver enabled
#define PORT_PAD_CTL_MODE   0x0006

#define PORT_PAD_CTL ((PORT_PAD_CTL_SMT     << 23) | \
                      (PORT_PAD_CTL_SR      << 22) | \
                      (PORT_PAD_CTL_DR_STR  << 20) | \
                      (PORT_PAD_CTL_REN     << 17) | \
                      (PORT_PAD_CTL_MODE    << 0))
                      
#define HIGH_DRIVE_8MA

void rgmii_configure_ports(in port p_rxclk, in port p_rxdv, in buffered port:1 p_rxer,
                           in buffered port:32 p_rxd_1000,
                           out port p_txclk, out port p_txen, out port p_txer,
                           out buffered port:32 p_txd,
                           clock rxclk, clock txclk)
{
  
  // Set output ports to 8mA drive strength
#ifdef HIGH_DRIVE_8MA
    asm volatile ("setc res[%0], %1" :: "r" (p_txclk), "r" (PORT_PAD_CTL));
    asm volatile ("setc res[%0], %1" :: "r" (p_txen) , "r" (PORT_PAD_CTL));
    asm volatile ("setc res[%0], %1" :: "r" (p_txer) , "r" (PORT_PAD_CTL));
    asm volatile ("setc res[%0], %1" :: "r" (p_txd)  , "r" (PORT_PAD_CTL));
#endif
  
  // RX ports
  configure_clock_src(rxclk, p_rxclk);
  configure_in_port_strobed_slave(p_rxd_1000, p_rxdv, rxclk);
  // Ensure that the error port is running fast enough to catch errors
  configure_in_port_strobed_slave(p_rxer, p_rxdv, rxclk);

  // TX ports
  configure_clock_xcore(txclk, 3); // Tile clock divided by 6
  configure_port_clock_output(p_txclk, txclk);
  configure_out_port_strobed_master(p_txd, p_txen, txclk, 0);
  configure_out_port(p_txer, txclk, 0);

  // Need to tune the following value to find middle of data eye.
  set_clock_rise_delay(rxclk, 3);
  set_clock_fall_delay(rxclk, 3);

  // Start the clocks
  start_clock(txclk);
  start_clock(rxclk);
}

void rgmii_ethernet_mac(server ethernet_rx_if i_rx_lp[n_rx_lp], static const unsigned n_rx_lp,
                        server ethernet_tx_if i_tx_lp[n_tx_lp], static const unsigned n_tx_lp,
                        streaming chanend ? c_rx_hp,
                        streaming chanend ? c_tx_hp,
                        streaming chanend c_rgmii_cfg,
                        rgmii_ports_t &rgmii_ports,
                        enum ethernet_enable_shaper_t enable_shaper)
{
  rx_client_state_t rx_client_state_lp[n_rx_lp];
  tx_client_state_t tx_client_state_lp[n_tx_lp];

  if (!ETHERNET_SUPPORT_HP_QUEUES && (!isnull(c_rx_hp) || !isnull(c_tx_hp))) {
    fail("Using high priority channels without #define ETHERNET_SUPPORT_HP_QUEUES set true");
  }

  init_rx_client_state(rx_client_state_lp, n_rx_lp);
  init_tx_client_state(tx_client_state_lp, n_tx_lp);

  mii_macaddr_hash_table_init();

  mii_init_lock();

  unsafe {
    unsigned int buffer_rx[RGMII_MAC_BUFFER_COUNT_RX * sizeof(mii_packet_t) / 4];
    unsigned int buffer_free_pointers_rx[RGMII_MAC_BUFFER_COUNT_RX];
    unsigned int buffer_used_pointers_rx_lp[RGMII_MAC_BUFFER_COUNT_RX + 1];
    unsigned int buffer_used_pointers_rx_hp[RGMII_MAC_BUFFER_COUNT_RX + 1];
    buffers_free_t free_buffers_rx;
    buffers_used_t used_buffers_rx_lp;
    buffers_used_t used_buffers_rx_hp;

    unsigned int buffer_tx_lp[RGMII_MAC_BUFFER_COUNT_TX * sizeof(mii_packet_t) / 4];
    unsigned int buffer_tx_hp[RGMII_MAC_BUFFER_COUNT_TX * sizeof(mii_packet_t) / 4];
    unsigned int buffer_free_pointers_tx_lp[RGMII_MAC_BUFFER_COUNT_TX];
    unsigned int buffer_free_pointers_tx_hp[RGMII_MAC_BUFFER_COUNT_TX];
    unsigned int buffer_used_pointers_tx_lp[RGMII_MAC_BUFFER_COUNT_TX + 1];
    unsigned int buffer_used_pointers_tx_hp[RGMII_MAC_BUFFER_COUNT_TX + 1];
    buffers_free_t free_buffers_tx_lp;
    buffers_free_t free_buffers_tx_hp;
    buffers_used_t used_buffers_tx_lp;
    buffers_used_t used_buffers_tx_hp;

    // Create unsafe pointers to pass to two parallel tasks
    buffers_used_t * unsafe p_used_buffers_rx_lp = &used_buffers_rx_lp;
    buffers_used_t * unsafe p_used_buffers_rx_hp = &used_buffers_rx_hp;
    buffers_free_t * unsafe p_free_buffers_rx = &free_buffers_rx;
    in buffered port:32 * unsafe p_rxd_1000_unsafe = &rgmii_ports.p_rxd_1000;
    in port * unsafe p_rxdv_unsafe = &rgmii_ports.p_rxdv;
    in buffered port:1 * unsafe p_rxer_unsafe = &rgmii_ports.p_rxer;
    rx_client_state_t * unsafe p_rx_client_state_lp =
      (rx_client_state_t * unsafe)&rx_client_state_lp[0];

    streaming chan c_rx_to_manager[2], c_manager_to_tx, c_ping_pong;
    streaming chanend * unsafe c_speed_change;
    int speed_change_ids[6];
    rgmii_inband_status_t current_mode = INITIAL_MODE;

    rgmii_configure_ports(rgmii_ports.p_rxclk, rgmii_ports.p_rxdv, rgmii_ports.p_rxer,
                          rgmii_ports.p_rxd_1000,
                          rgmii_ports.p_txclk, rgmii_ports.p_txen, rgmii_ports.p_txer,
                          rgmii_ports.p_txd,
                          rgmii_ports.rxclk, rgmii_ports.txclk);

    log_speed_change_pointers(speed_change_ids);
    c_speed_change = (streaming chanend * unsafe)speed_change_ids;

    ethernet_port_state_t port_state;
    init_server_port_state(port_state, enable_shaper == ETHERNET_ENABLE_SHAPER);

    ethernet_port_state_t * unsafe p_port_state = (ethernet_port_state_t * unsafe)&port_state;

    while(1)
    {
      // Setup the buffer pointers
      buffers_used_initialize(used_buffers_rx_lp, buffer_used_pointers_rx_lp);
      buffers_used_initialize(used_buffers_rx_hp, buffer_used_pointers_rx_hp);
      buffers_free_initialize(free_buffers_rx, (unsigned char*)buffer_rx,
                              buffer_free_pointers_rx, RGMII_MAC_BUFFER_COUNT_RX);

      buffers_used_initialize(used_buffers_tx_lp, buffer_used_pointers_tx_lp);
      buffers_used_initialize(used_buffers_tx_hp, buffer_used_pointers_tx_hp);
      buffers_free_initialize(free_buffers_tx_lp, (unsigned char*)buffer_tx_lp,
                              buffer_free_pointers_tx_lp, RGMII_MAC_BUFFER_COUNT_TX);
      buffers_free_initialize(free_buffers_tx_hp, (unsigned char*)buffer_tx_hp,
                              buffer_free_pointers_tx_hp, RGMII_MAC_BUFFER_COUNT_TX);

      // Disable MII (10/100) for now.
/*       if (current_mode == INBAND_STATUS_100M_FULLDUPLEX_UP ||
          current_mode == INBAND_STATUS_100M_FULLDUPLEX_DOWN ||
          current_mode == INBAND_STATUS_10M_FULLDUPLEX_UP ||
          current_mode == INBAND_STATUS_10M_FULLDUPLEX_DOWN)
      {
        mii_macaddr_set_num_active_filters(1);

        par
        {
          {
            rgmii_10_100_master_tx_pins(c_manager_to_tx, rgmii_ports.p_txd, c_speed_change[0]);
            empty_channel(c_manager_to_tx);
          }

          {
            clearbuf(rgmii_ports.p_rxd_10_100);
            par {
              {
                rgmii_10_100_master_rx_pins(c_rx_to_manager[0], rgmii_ports.p_rxd_10_100, rgmii_ports.p_rxdv,
                                            rgmii_ports.p_rxer, c_speed_change[1]);
                empty_channel(c_rx_to_manager[0]);
              }
              {
                rgmii_buffer_manager(c_rx_to_manager[0], c_speed_change[3],
                                     *p_used_buffers_rx_lp, *p_used_buffers_rx_hp, *p_free_buffers_rx, 0);
              }
              {
                // Just wait for a change from 100Mb mode and empty those channels
                c_speed_change[2] :> unsigned tmp;
                c_speed_change[4] :> unsigned tmp;
              }
            }
          }

          {
            rgmii_ethernet_rx_server((rx_client_state_t *)p_rx_client_state_lp, i_rx_lp, n_rx_lp,
                                     c_rx_hp, c_rgmii_cfg, rgmii_ports.p_rxd_interframe,
                                     *p_used_buffers_rx_lp, *p_used_buffers_rx_hp,
                                     *p_free_buffers_rx, current_mode, speed_change_ids, p_port_state);
          }

          {
            rgmii_ethernet_tx_server(tx_client_state_lp, i_tx_lp, n_tx_lp,
                                     c_tx_hp,
                                     c_manager_to_tx, c_speed_change[5],
                                     used_buffers_tx_lp, free_buffers_tx_lp,
                                     used_buffers_tx_hp, free_buffers_tx_hp,
                                     p_port_state);
          }
        }
      }
      else
       */
      {
        mii_macaddr_set_num_active_filters(2);

        par
        {
          {
            rgmii_tx_lld(c_manager_to_tx, rgmii_ports.p_txd, c_speed_change[0]);
            empty_channel(c_manager_to_tx);
          }

          {
            clearbuf(*p_rxd_1000_unsafe);
            par {
              {
                rgmii_rx_lld(c_rx_to_manager[0], c_ping_pong, 0, c_speed_change[1],
                            *p_rxd_1000_unsafe, *p_rxdv_unsafe, *p_rxer_unsafe);
                empty_channel(c_rx_to_manager[0]);
                empty_channel(c_ping_pong);
              }
              {
                rgmii_rx_lld(c_rx_to_manager[1], c_ping_pong, 1, c_speed_change[2],
                            *p_rxd_1000_unsafe, *p_rxdv_unsafe, *p_rxer_unsafe);
                empty_channel(c_rx_to_manager[1]);
                empty_channel(c_ping_pong);
              }
              {
                rgmii_buffer_manager(c_rx_to_manager[0], c_speed_change[3],
                                     *p_used_buffers_rx_lp, *p_used_buffers_rx_hp, *p_free_buffers_rx, 0);
              }
              {
                rgmii_buffer_manager(c_rx_to_manager[1], c_speed_change[4],
                                     *p_used_buffers_rx_lp, *p_used_buffers_rx_hp, *p_free_buffers_rx, 1);
              }
            }
          }

          {
            rgmii_ethernet_rx_server((rx_client_state_t *)p_rx_client_state_lp, i_rx_lp, n_rx_lp,
                                     c_rx_hp, c_rgmii_cfg, //rgmii_ports.p_rxd_interframe,
                                     *p_used_buffers_rx_lp, *p_used_buffers_rx_hp,
                                     *p_free_buffers_rx, current_mode, speed_change_ids,
                                     p_port_state);
          }

          {
            rgmii_ethernet_tx_server(tx_client_state_lp, i_tx_lp, n_tx_lp,
                                     c_tx_hp,
                                     c_manager_to_tx, c_speed_change[5],
                                     used_buffers_tx_lp, free_buffers_tx_lp,
                                     used_buffers_tx_hp, free_buffers_tx_hp,
                                     p_port_state);
          }
        }
      }
    }
  }
}
