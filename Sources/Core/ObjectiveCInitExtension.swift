//
//  ObjectiveCInitExtension.swift
//  plank
//
//  Created by Rahul Malik on 2/14/17.
//
//

import Foundation

let dateValueTransformerKey = "kPlankDateValueTransformerKey"

extension ObjCFileRenderer {
    func renderPostInitNotification(type: String) -> String {
        return "[[NSNotificationCenter defaultCenter] postNotificationName:kPlankDidInitializeNotification object:self userInfo:@{ kPlankInitTypeKey : @(\(type)) }];"
    }
}

extension ObjCModelRenderer {

    func renderModelObjectWithDictionary() -> ObjCIR.Method {
        return ObjCIR.method("+ (instancetype)modelObjectWithDictionary:(NSDictionary *)dictionary") {
            ["return [[self alloc] initWithModelDictionary:dictionary];"]
        }
    }

    func renderDesignatedInit() -> ObjCIR.Method {
        return ObjCIR.method("- (instancetype)init") {
            [
                "return [self initWithModelDictionary:@{}];"
            ]
        }
    }

    func renderInitWithBuilder() -> ObjCIR.Method {
        return ObjCIR.method("- (instancetype)initWithBuilder:(\(builderClassName) *)builder") {
            [
                "NSParameterAssert(builder);",
                "return [self initWithBuilder:builder initType:PlankModelInitTypeDefault];"
            ]
        }
    }

    func renderInitWithBuilderWithInitType() -> ObjCIR.Method {
        return ObjCIR.method("- (instancetype)initWithBuilder:(\(builderClassName) *)builder initType:(PlankModelInitType)initType") {
            [
                "NSParameterAssert(builder);",
                self.isBaseClass ? ObjCIR.ifStmt("!(self = [super init])") { ["return self;"] } :
                    ObjCIR.ifStmt("!(self = [super initWithBuilder:builder initType:initType])") { ["return self;"] },
                self.properties.map { (name, _) in
                    "_\(name.snakeCaseToPropertyName()) = builder.\(name.snakeCaseToPropertyName());"
                    }.joined(separator: "\n"),
                "_\(self.dirtyPropertiesIVarName) = builder.\(self.dirtyPropertiesIVarName);",
                ObjCIR.ifStmt("[self class] == [\(self.className) class]") {
                    [renderPostInitNotification(type: "initType")]
                },
                "return self;"
            ]
        }
    }

    public func renderInitWithModelDictionary() -> ObjCIR.Method {
        func renderPropertyInit(
            _ propertyToAssign: String,
            _ rawObjectName: String,
            schema: Schema,
            firstName: String, // TODO: HACK to get enums to work (not clean)
            counter: Int = 0
            ) -> [String] {
            switch schema {
            case .Array(itemType: .some(let itemType)):
                let currentResult = "result\(counter)"
                let currentTmp = "tmp\(counter)"
                let currentObj = "obj\(counter)"
                return [
                    "NSArray *items = \(rawObjectName);",
                    "NSMutableArray *\(currentResult) = [NSMutableArray arrayWithCapacity:items.count];",
                    ObjCIR.forStmt("id \(currentObj) in items") { [
                        ObjCIR.ifStmt("[\(currentObj) isEqual:[NSNull null]] == NO") { [
                            "id \(currentTmp) = nil;",
                            renderPropertyInit(currentTmp, currentObj, schema: itemType, firstName: firstName, counter: counter + 1).joined(separator: "\n"),
                            ObjCIR.ifStmt("\(currentTmp) != nil") {[
                                "[\(currentResult) addObject:\(currentTmp)];"
                                ]}
                            ]}
                        ]},
                    "\(propertyToAssign) = \(currentResult);"
                ]
            case .Map(valueType: .some(let valueType)) where valueType.isObjCPrimitiveType == false:
                let currentResult = "result\(counter)"
                let currentItems = "items\(counter)"
                let (currentKey, currentObj, currentStop) = ("key\(counter)", "obj\(counter)", "stop\(counter)")
                return [
                    "NSDictionary *\(currentItems) = \(rawObjectName);",
                    "NSMutableDictionary *\(currentResult) = [NSMutableDictionary dictionaryWithCapacity:\(currentItems).count];",
                    ObjCIR.stmt(
                        ObjCIR.msg(currentItems,
                                   ("enumerateKeysAndObjectsUsingBlock",
                                    ObjCIR.block(["NSString *  _Nonnull \(currentKey)",
                                        "id  _Nonnull \(currentObj)",
                                        "__unused BOOL * _Nonnull \(currentStop)"]) {
                                            [
                                                ObjCIR.ifStmt("\(currentObj) != nil && [\(currentObj) isEqual:[NSNull null]] == NO") {
                                                    renderPropertyInit("\(currentResult)[\(currentKey)]", currentObj, schema: valueType, firstName: firstName, counter: counter + 1)
                                                }
                                            ]
                                   })
                        )
                    ),
                    "\(propertyToAssign) = \(currentResult);"
                ]
            case .Float:
                return ["\(propertyToAssign) = [\(rawObjectName) doubleValue];"]
            case .Integer:
                return ["\(propertyToAssign) = [\(rawObjectName) integerValue];"]
            case .Boolean:
                return ["\(propertyToAssign) = [\(rawObjectName) boolValue];"]
            case .String(format: .some(.Uri)):
                return ["\(propertyToAssign) = [NSURL URLWithString:\(rawObjectName)];"]
            case .String(format: .some(.DateTime)):
                return ["\(propertyToAssign) = [[NSValueTransformer valueTransformerForName:\(dateValueTransformerKey)] transformedValue:\(rawObjectName)];"]
            case .Reference(with: let ref):
                return ref.force().map {
                    renderPropertyInit(propertyToAssign, rawObjectName, schema: $0, firstName: firstName, counter: counter)
                    } ?? {
                        assert(false, "TODO: Forward optional across methods")
                        return []
                    }()
            case .Enum(.Integer(let variants)):
                return renderPropertyInit(propertyToAssign, rawObjectName, schema: .Integer, firstName: firstName, counter: counter)
            case .Enum(.String(let variants)):
                return ["\(propertyToAssign) = \(enumFromStringMethodName(propertyName: firstName, className: className))(value);"]
            case .Object(let objectRoot):
                return ["\(propertyToAssign) = [\(objectRoot.className(with: self.params)) modelObjectWithDictionary:\(rawObjectName)];"]
            case .OneOf(types: let schemas):
                // TODO Update to create ADT objects
                let adtClassName = self.objcClassFromSchema(firstName, schema).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                func loop(schema: Schema) -> String {
                    func transformToADTInit(_ lines: [String]) -> [String] {
                        if let assignmentLine = lines.last {
                            let propAssignmentPrefix = "\(propertyToAssign) = "
                            if assignmentLine.hasPrefix(propAssignmentPrefix) {
                                let propertyInitStatement = assignmentLine.substring(from: propAssignmentPrefix.endIndex).trimmingCharacters(in: CharacterSet.init(charactersIn: " ;"))
                                let adtInitStatement = propAssignmentPrefix + "[\(adtClassName) objectWith\(ObjCADTRenderer.objectName(schema)):\(propertyInitStatement)];"
                                return lines.dropLast() + [adtInitStatement]
                            }
                        }
                        return lines
                    }

                    switch schema {
                    case .Object(let objectRoot):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSDictionary class]] && [\(rawObjectName)[\("type".objcLiteral())] isEqualToString:\(objectRoot.typeIdentifier.objcLiteral())]") {
                            transformToADTInit(["\(propertyToAssign) = [\(objectRoot.className(with: self.params)) modelObjectWithDictionary:\(rawObjectName)];"])
                        }
                    case .Reference(with: let ref):
                        return ref.force().map(loop) ?? {
                            assert(false, "TODO: Forward optional across methods")
                            return ""
                            }()
                    case .Float:
                        let encodingConditions = [
                            "strcmp([\(rawObjectName) objCType], @encode(float)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(double)) == 0"
                        ]

                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSNumber class]] && (\(encodingConditions.joined(separator: " ||\n")))") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: .Float, firstName: firstName, counter: counter))
                        }
                    case .Integer, .Enum(.Integer(_)):
                        let encodingConditions = [
                            "strcmp([\(rawObjectName) objCType], @encode(int)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(unsigned int)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(short)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(unsigned short)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(long)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(long long)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(unsigned long)) == 0",
                            "strcmp([\(rawObjectName) objCType], @encode(unsigned long long)) == 0"
                        ]
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSNumber class]] && (\(encodingConditions.joined(separator: " ||\n")))") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }

                    case .Boolean:
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSNumber class]] && strcmp([\(rawObjectName) objCType], @encode(BOOL)) == 0") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .Array(itemType: _):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSArray class]]") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .Map(valueType: _):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSDictionary class]]") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .String(.some(.Uri)):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSString class]] && [NSURL URLWithString:\(rawObjectName)] != nil") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .String(.some(.DateTime)):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSString class]] && [[NSValueTransformer valueTransformerForName:\(dateValueTransformerKey)] transformedValue:\(rawObjectName)] != nil") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .String(.some(_)), .String(.none), .Enum(.String(_)):
                        return ObjCIR.ifStmt("[\(rawObjectName) isKindOfClass:[NSString class]]") {
                            return transformToADTInit(renderPropertyInit(propertyToAssign, rawObjectName, schema: schema, firstName: firstName, counter: counter))
                        }
                    case .OneOf(types:_):
                        fatalError("Nested oneOf types are unsupported at this time. Please file an issue if you require this.")
                    }
                }

                return schemas.map(loop)
            default:
                return ["\(propertyToAssign) = \(rawObjectName);"]
            }
        }

        return ObjCIR.method("- (instancetype)initWithModelDictionary:(NSDictionary *)modelDictionary") {
            let x: [String] = self.properties.map { (name, schema) in
                ObjCIR.ifStmt("[key isEqualToString:\(name.objcLiteral())]") {
                    [
                        "id value = valueOrNil(modelDictionary, \(name.objcLiteral()));",
                        ObjCIR.ifStmt("value != nil") {
                            renderPropertyInit("self->_\(name.snakeCaseToPropertyName())", "value", schema: schema, firstName: name)
                        },
                        "self->_\(dirtyPropertiesIVarName).\(dirtyPropertyOption(propertyName: name, className: className)) = 1;"
                    ]
                }
            }

            return [
                "NSParameterAssert(modelDictionary);",
                self.isBaseClass ? ObjCIR.ifStmt("!(self = [super init])") { ["return self;"] } :
                "if (!(self = [super initWithModelDictionary:modelDictionary])) { return self; }",
                ObjCIR.stmt(
                    ObjCIR.msg("modelDictionary",
                               ("enumerateKeysAndObjectsUsingBlock", ObjCIR.block(["NSString *  _Nonnull key",
                                                                                   "id  _Nonnull obj",
                                                                                   "__unused BOOL * _Nonnull stop"]) {
                                                                                    x
                                }
                        )
                )),
                ObjCIR.ifStmt("[self class] == [\(self.className) class]") {
                    [renderPostInitNotification(type: "PlankModelInitTypeDefault")]
                },
                "return self;"
            ]
        }
    }
}
