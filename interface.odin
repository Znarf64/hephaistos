package hephaistos

import "base:runtime"

import spv "spirv-odin"

Interface_Usage :: enum {
	In = 1,
	Out,
}

Interface_Info :: struct {
	type:  ^Type,
	usage: [Shader_Stage]Interface_Usage,
	id:    spv.BuiltIn,
}

interface_infos: map[string]Interface_Info

@(init)
_interface_infos_init :: proc "contextless" () {
	context = runtime.default_context()

	_base_types_init()

	interface_infos["Position"          ] = { type = t_vec4,  usage = #partial { .Vertex   = .Out, .Tesselation_Control = .Out, .Tesselation_Evaluation = .Out, .Geometry = .Out, }, id = .Position,           }
	interface_infos["PointSize"         ] = { type = t_f32,   usage = #partial { .Vertex   = .Out, .Tesselation_Control = .Out, .Tesselation_Evaluation = .Out, .Geometry = .Out, }, id = .PointSize,          }
	interface_infos["VertexIndex"       ] = { type = t_i32,   usage = #partial { .Vertex   = .In,                                                                                 }, id = .VertexIndex,        }
	interface_infos["VertexID"          ] = { type = t_i32,   usage = #partial { .Vertex   = .In,                                                                                 }, id = .VertexId,           }
	interface_infos["InstanceId"        ] = { type = t_i32,   usage = #partial { .Geometry = .In,                                                                                 }, id = .InstanceId,         }
	interface_infos["InstanceIndex"     ] = { type = t_i32,   usage = #partial { .Geometry = .In,                                                                                 }, id = .InstanceId,         }
	interface_infos["PrimitiveId"       ] = { type = t_i32,   usage = #partial { .Fragment = .In, .Geometry = .In,                                                                }, id = .PrimitiveId,        }
	interface_infos["InvocationId"      ] = { type = t_i32,   usage = #partial { .Geometry = .In, .Tesselation_Control  = .In,                                                    }, id = .InvocationId,       }
	interface_infos["Layer"             ] = { type = t_i32,   usage = #partial { .Geometry = .Out,                                                                                }, id = .Layer,              }
	interface_infos["ViewportIndex"     ] = { type = t_i32,   usage = #partial { .Geometry = .Out,                                                                                }, id = .ViewportIndex,      }
	interface_infos["FragCoord"         ] = { type = t_vec4,  usage = #partial { .Fragment = .In,                                                                                 }, id = .FragCoord,          }
	interface_infos["FragDepth"         ] = { type = t_f32,   usage = #partial { .Fragment = .Out,                                                                                }, id = .FragDepth,          }
	interface_infos["GlobalInvocationId"] = { type = t_ivec3, usage = #partial { .Compute  = .In,                                                                                 }, id = .GlobalInvocationId, }
	interface_infos["NumWorkgroups"     ] = { type = t_ivec3, usage = #partial { .Compute  = .In,                                                                                 }, id = .NumWorkgroups,      }

	interface_infos["LaunchId"           ] = { type = t_ivec3,     usage = #partial { .Ray_Generation = .In, .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .LaunchIdKHR,            }
	interface_infos["LaunchSize"         ] = { type = t_ivec3,     usage = #partial { .Ray_Generation = .In, .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .LaunchSizeKHR,          }
	interface_infos["WorldRayOrigin"     ] = { type = t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .WorldRayOriginKHR,      }
	interface_infos["WorldRayDirection"  ] = { type = t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .WorldRayDirectionKHR,   }
	interface_infos["ObjectRayOrigin"    ] = { type = t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectRayOriginKHR,     }
	interface_infos["ObjectRayDirection" ] = { type = t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectRayDirectionKHR,  }
	interface_infos["RayTmin"            ] = { type = t_f32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .RayTminKHR,             }
	interface_infos["RayTmax"            ] = { type = t_f32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .RayTmaxKHR,             }
	interface_infos["InstanceCustomIndex"] = { type = t_i32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .InstanceCustomIndexKHR, }
	interface_infos["ObjectToWorld"      ] = { type = t_mat4x3,    usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectToWorldKHR,       }
	interface_infos["WorldToObject"      ] = { type = t_mat4x3,    usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .WorldToObjectKHR,       }
	interface_infos["HitKind"            ] = { type = t_Hit_Kind,  usage = #partial {                                             .Any_Hit = .In, .Closest_Hit = .In,              }, id = .HitKindKHR,             }
	interface_infos["IncomingRayFlags"   ] = { type = t_Ray_Flags, usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .IncomingRayFlagsKHR,    }
	interface_infos["RayGeometryIndex"   ] = { type = t_i32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .RayGeometryIndexKHR,    }

	interface_infos["BaryCoord"       ] = { type = t_vec3,  usage = #partial { .Fragment = .In, }, id = .BaryCoordKHR,        }
	interface_infos["BaryCoordNoPersp"] = { type = t_vec3,  usage = #partial { .Fragment = .In, }, id = .BaryCoordNoPerspKHR, }
}
