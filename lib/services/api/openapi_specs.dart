/// OpenAPI 3.0.3 machine-readable specification generator for Lumen Local REST API.
class OpenApiSpecs {
  static Map<String, dynamic> generateSpec({int port = 18080}) {
    return {
      'openapi': '3.0.3',
      'info': {
        'title': 'Lumen Local REST & SSE API',
        'version': '1.2.0',
        'description':
            'High-performance local REST & Server-Sent Events (SSE) API for electricity status monitoring, DTEK outage schedules, countdown timers, outage history, and analytics.',
      },
      'servers': [
        {
          'url': 'http://127.0.0.1:$port/api/v1',
          'description': 'Localhost Server (IPv4 loopback)',
        }
      ],
      'paths': {
        '/status': {
          'get': {
            'summary': 'Combined dashboard status snapshot',
            'description':
                'Returns current real power state, today\'s schedule, and countdown timer in a single unified payload.',
            'parameters': [
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'GPV group key (e.g. GPV2.1)'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/health': {
          'get': {
            'summary': 'Healthcheck & module status',
            'description':
                'Returns service uptime, platform, and application version.',
            'responses': {
              '200': {'description': 'OK'}
            }
          }
        },
        '/docs': {
          'get': {
            'summary': 'Interactive Swagger UI Documentation',
            'description':
                'Serves an interactive Swagger UI page for exploring and testing API endpoints directly from the browser.',
            'responses': {
              '200': {
                'description': 'Interactive Swagger UI HTML page',
                'content': {
                  'text/html': {
                    'schema': {'type': 'string'}
                  }
                }
              }
            }
          }
        },
        '/stream': {
          'get': {
            'summary': 'Server-Sent Events (SSE) real-time event stream',
            'description':
                'Establishes a persistent SSE stream broadcasting real-time power changes and schedule updates.',
            'responses': {
              '200': {
                'description': 'SSE stream established',
                'content': {
                  'text/event-stream': {
                    'schema': {'type': 'string'}
                  }
                }
              }
            }
          }
        },
        '/power/current': {
          'get': {
            'summary': 'Current power & sensor state',
            'description':
                'Real power presence status (online/offline/unknown), sensor staleness, and reason diagnostics.',
            'responses': {
              '200': {'description': 'OK'}
            }
          }
        },
        '/power/events': {
          'get': {
            'summary': 'Power event log',
            'parameters': [
              {
                'name': 'date',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'Filter by single date YYYY-MM-DD'
              },
              {
                'name': 'from',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'Start date YYYY-MM-DD'
              },
              {
                'name': 'to',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'End date YYYY-MM-DD'
              },
              {
                'name': 'limit',
                'in': 'query',
                'schema': {'type': 'integer', 'default': 100},
                'description': 'Maximum number of events to return (1-1000)'
              },
              {
                'name': 'sort',
                'in': 'query',
                'schema': {
                  'type': 'string',
                  'enum': ['desc', 'asc'],
                  'default': 'desc'
                },
                'description': 'Chronological sort order'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid date format'}
            }
          },
          'post': {
            'summary': 'Add manual power event',
            'description':
                'Records a manual power online/offline transition directly into local storage and recalculates status without external network delays.',
            'requestBody': {
              'required': true,
              'content': {
                'application/json': {
                  'schema': {
                    'type': 'object',
                    'required': ['status'],
                    'properties': {
                      'status': {
                        'type': 'string',
                        'enum': ['online', 'offline']
                      },
                      'timestamp': {
                        'type': 'string',
                        'description':
                            'ISO8601 or YYYY-MM-DD HH:mm:ss (defaults to now)'
                      },
                      'device': {'type': 'string', 'default': 'API Client'}
                    }
                  }
                }
              }
            },
            'responses': {
              '200': {'description': 'Event created successfully'},
              '400': {
                'description': 'Bad Request (invalid JSON, status or timestamp)'
              }
            }
          }
        },
        '/power/intervals': {
          'get': {
            'summary': 'Calculated real outage intervals',
            'parameters': [
              {
                'name': 'date',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'Date in YYYY-MM-DD format (defaults to today)'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid date format'}
            }
          }
        },
        '/power/refresh': {
          'post': {
            'summary': 'Trigger sensor background polling',
            'description':
                'Triggers background polling of Firebase sensor without blocking the caller.',
            'responses': {
              '200': {'description': 'Sensor disabled in settings'},
              '202': {'description': 'Refresh scheduled'}
            }
          }
        },
        '/schedule/today': {
          'get': {
            'summary': 'Today\'s outage schedule',
            'parameters': [
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'GPV group key (e.g. GPV2.1)'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/schedule/tomorrow': {
          'get': {
            'summary': 'Tomorrow\'s outage schedule',
            'parameters': [
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'GPV group key (e.g. GPV2.1)'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/schedule/group/{id}': {
          'get': {
            'summary':
                'Combined today and tomorrow schedule for a specific GPV group',
            'parameters': [
              {
                'name': 'id',
                'in': 'path',
                'required': true,
                'schema': {'type': 'string'},
                'description': 'GPV group identifier (e.g. GPV2.1, GPV1.2)'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Unknown group identifier'}
            }
          }
        },
        '/schedule/countdown': {
          'get': {
            'summary': 'Countdown to next scheduled outage or restoration',
            'parameters': [
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/schedule/groups': {
          'get': {
            'summary': 'Overview of all 12 GPV groups',
            'responses': {
              '200': {'description': 'OK'}
            }
          }
        },
        '/schedule/sync': {
          'post': {
            'summary': 'Trigger immediate schedule re-fetch from DTEK',
            'parameters': [
              {
                'name': 'force',
                'in': 'query',
                'schema': {'type': 'boolean', 'default': false}
              }
            ],
            'responses': {
              '200': {'description': 'Sync completed or cooldown active'}
            }
          }
        },
        '/history/versions': {
          'get': {
            'summary': 'DTEK schedule revision history for a date',
            'parameters': [
              {
                'name': 'date',
                'in': 'query',
                'schema': {'type': 'string'}
              },
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid parameters'}
            }
          }
        },
        '/history/dates': {
          'get': {
            'summary': 'List of all dates available in local database',
            'responses': {
              '200': {'description': 'OK'}
            }
          }
        },
        '/history/export': {
          'get': {
            'summary': 'Export database history to JSON',
            'parameters': [
              {
                'name': 'from',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'Start date YYYY-MM-DD'
              },
              {
                'name': 'to',
                'in': 'query',
                'schema': {'type': 'string'},
                'description': 'End date YYYY-MM-DD'
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid date range'}
            }
          }
        },
        '/history/logs': {
          'get': {
            'summary': 'System and application diagnostic logs',
            'parameters': [
              {
                'name': 'limit',
                'in': 'query',
                'schema': {'type': 'integer', 'default': 50}
              }
            ],
            'responses': {
              '200': {'description': 'OK'}
            }
          }
        },
        '/analytics/stats': {
          'get': {
            'summary': 'Aggregate outage statistics for period',
            'parameters': [
              {
                'name': 'days',
                'in': 'query',
                'schema': {'type': 'integer', 'default': 7}
              },
              {
                'name': 'mode',
                'in': 'query',
                'schema': {
                  'type': 'string',
                  'enum': ['real', 'predicted'],
                  'default': 'real'
                }
              },
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/analytics/accuracy': {
          'get': {
            'summary': 'DTEK schedule accuracy score compared to sensor',
            'parameters': [
              {
                'name': 'days',
                'in': 'query',
                'schema': {'type': 'integer', 'default': 7}
              },
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/analytics/switch-lag': {
          'get': {
            'summary': 'Average switch lag (early/late switching)',
            'parameters': [
              {
                'name': 'days',
                'in': 'query',
                'schema': {'type': 'integer', 'default': 7}
              },
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        },
        '/analytics/records': {
          'get': {
            'summary': 'Outage & uptime extreme records',
            'parameters': [
              {
                'name': 'mode',
                'in': 'query',
                'schema': {
                  'type': 'string',
                  'enum': ['real', 'predicted'],
                  'default': 'real'
                }
              },
              {
                'name': 'group',
                'in': 'query',
                'schema': {'type': 'string'}
              }
            ],
            'responses': {
              '200': {'description': 'OK'},
              '400': {'description': 'Invalid group provided'}
            }
          }
        }
      }
    };
  }
}
