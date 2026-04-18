package hephaistos_checker

import "base:runtime"

import "../ast"
import "../types"

import spv "../spirv-odin"

Interface_Usage :: enum {
	In = 1,
	Out,
}

Interface_Info :: struct {
	type:  ^types.Type,
	usage: [ast.Shader_Stage]Interface_Usage,
	id:    spv.BuiltIn,
}

interface_infos: map[string]Interface_Info

@(init)
_interface_infos_init :: proc "contextless" () {
	context = runtime.default_context()

	interface_infos["Position"          ] = { type = types.t_vec4,  usage = #partial { .Vertex   = .Out, .Tesselation_Control = .Out, .Tesselation_Evaluation = .Out, .Geometry = .Out, }, id = .Position,           }
	interface_infos["PointSize"         ] = { type = types.t_f32,   usage = #partial { .Vertex   = .Out, .Tesselation_Control = .Out, .Tesselation_Evaluation = .Out, .Geometry = .Out, }, id = .PointSize,          }
	interface_infos["VertexIndex"       ] = { type = types.t_i32,   usage = #partial { .Vertex   = .In,                                                                                 }, id = .VertexIndex,        }
	interface_infos["VertexID"          ] = { type = types.t_i32,   usage = #partial { .Vertex   = .In,                                                                                 }, id = .VertexId,           }
	interface_infos["InstanceId"        ] = { type = types.t_i32,   usage = #partial { .Geometry = .In,                                                                                 }, id = .InstanceId,         }
	interface_infos["InstanceIndex"     ] = { type = types.t_i32,   usage = #partial { .Geometry = .In,                                                                                 }, id = .InstanceId,         }
	interface_infos["PrimitiveId"       ] = { type = types.t_i32,   usage = #partial { .Geometry = .In,                                                                                 }, id = .PrimitiveId,        }
	interface_infos["InvocationId"      ] = { type = types.t_i32,   usage = #partial { .Geometry = .In, .Tesselation_Control  = .In,                                                    }, id = .InvocationId,       }
	interface_infos["Layer"             ] = { type = types.t_i32,   usage = #partial { .Geometry = .Out,                                                                                }, id = .Layer,              }
	interface_infos["ViewportIndex"     ] = { type = types.t_i32,   usage = #partial { .Geometry = .Out,                                                                                }, id = .ViewportIndex,      }
	interface_infos["FragCoord"         ] = { type = types.t_vec4,  usage = #partial { .Fragment = .In,                                                                                 }, id = .FragCoord,          }
	interface_infos["FragDepth"         ] = { type = types.t_f32,   usage = #partial { .Fragment = .In,                                                                                 }, id = .FragDepth,          }
	interface_infos["GlobalInvocationId"] = { type = types.t_ivec3, usage = #partial { .Compute  = .In,                                                                                 }, id = .GlobalInvocationId, }
	interface_infos["NumWorkgroups"     ] = { type = types.t_ivec3, usage = #partial { .Compute  = .In,                                                                                 }, id = .NumWorkgroups,      }

	interface_infos["LaunchId"           ] = { type = types.t_ivec3,     usage = #partial { .Ray_Generation = .In, .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .LaunchIdKHR,            }
	interface_infos["LaunchSize"         ] = { type = types.t_ivec3,     usage = #partial { .Ray_Generation = .In, .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .LaunchSizeKHR,          }
	interface_infos["WorldRayOrigin"     ] = { type = types.t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .WorldRayOriginKHR,      }
	interface_infos["WorldRayDirection"  ] = { type = types.t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .WorldRayDirectionKHR,   }
	interface_infos["ObjectRayOrigin"    ] = { type = types.t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectRayOriginKHR,     }
	interface_infos["ObjectRayDirection" ] = { type = types.t_vec3,      usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectRayDirectionKHR,  }
	interface_infos["RayTmin"            ] = { type = types.t_f32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .RayTminKHR,             }
	interface_infos["RayTmax"            ] = { type = types.t_f32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .RayTmaxKHR,             }
	interface_infos["InstanceCustomIndex"] = { type = types.t_i32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .InstanceCustomIndexKHR, }
	interface_infos["ObjectToWorld"      ] = { type = types.t_mat4x3,    usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .ObjectToWorldKHR,       }
	interface_infos["WorldToObject"      ] = { type = types.t_mat4x3,    usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .WorldToObjectKHR,       }
	interface_infos["HitKind"            ] = { type = types.t_Hit_Kind,  usage = #partial {                                             .Any_Hit = .In, .Closest_Hit = .In,              }, id = .HitKindKHR,             }
	interface_infos["IncomingRayFlags"   ] = { type = types.t_Ray_Flags, usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In, .Miss = .In, }, id = .IncomingRayFlagsKHR,    }
	interface_infos["RayGeometryIndex"   ] = { type = types.t_i32,       usage = #partial {                        .Intersection = .In, .Any_Hit = .In, .Closest_Hit = .In,              }, id = .RayGeometryIndexKHR,    }
}
