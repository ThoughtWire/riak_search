% -*- mode: erlang -*-
{application, raptor,
 [{description,  "Interface to Raptor indexing engine"},
  {vsn,          "0.1"},
  {modules,      [raptor_pb,
                  raptor_conn,
                  raptor_conn_sup,
                  raptor_monitor,
                  raptor_sup,
                  raptor_util,
                  raptor_app]},
  {registered,   [raptor_conn_sup]},
  {applications, [kernel, stdlib, sasl]},
  {mod, {raptor_app, []}}]}.