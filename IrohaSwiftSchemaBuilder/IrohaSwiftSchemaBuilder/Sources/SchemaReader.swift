//
// Copyright 2021 Soramitsu Co., Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

// MARK: - TypeKind

indirect enum TypeKind {
    
    case uint8
    case uint16
    case uint32
    case uint64
    case uint128
    
    case int8
    case int16
    case int32
    case int64
    
    case compact
    case fixedPoint(String, UInt)
    
    case string
    case boolean
    
    case map(String, String) // pair of ref names
    case vector(String) // ref name,
    case array(String, UInt) // ref name + length
    case fixedSizeArray(String, UInt) // ref name + length

    case `struct`([(String, String)]) // pairs of name + ref name
    case tupleStruct([String]) // array of ref names

    case `enum`([(String, UInt8, [String]?)]) // pairs of case + array of ref names

    case optional(String) // ref name
}

// MARK: - TypeMetadata

struct TypeMetadata {
    var name: String
    let kind: TypeKind
}

// MARK: - SchemaReader

struct SchemaReader {
    
    private let typeResolver = TypeResolver()
    
    let rawSchema: [String: Any]
    private var schema: [String: TypeMetadata]?
    
    init(rawSchema: [String: Any]) {
        self.rawSchema = rawSchema
    }
    
    mutating func parse() -> Result<[String: TypeMetadata], Error> {
        if let schema = schema {
            return .success(schema)
        }
        
        var schema: [String: TypeMetadata] = [:]
        for (name, value) in rawSchema {
            switch typeResolver.resolveTypeMetadata(name: name, value: value) {
            case let .success(metadata):
                schema[name] = metadata
                break
            case let .failure(error):
                return .failure(error)
            }
        }
        
        self.schema = schema
        return .success(schema)
    }
}

// MARK: - TypeResolver

private struct TypeResolver {
    
    enum Error: LocalizedError {
        case unexpectedType
        case unknownType(Any)
        case other(String)
        
        var errorDescription: String? {
            switch self {
            case .unexpectedType: return "Unexpected type"
            case let .unknownType(type): return "Unknown type: \(type)"
            case let .other(string): return string
            }
        }
    }
    
    func resolveTypeMetadata(name: String, value: Any? = nil) -> Result<TypeMetadata, Error> {
        let kind: TypeKind
        var name = name
        
        switch name {
        
        case "String": kind = .string
        case "bool": kind = .boolean
        case "u8": kind = .uint8
        case "u16": kind = .uint16
        case "u32": kind = .uint32
        case "u64": kind = .uint64
        case "u128": kind = .uint128
        case "i8": kind = .int8
        case "i16": kind = .int16
        case "i32": kind = .int32
        case "i64": kind = .int64
            
        default:
            guard let value = value else { return .failure(Error.unexpectedType) }
            
            switch resolveTypeKind(name: name, value: value) {
            case let .success(resolvedKind):
                kind = resolvedKind
                
                if case let .fixedSizeArray(fixedSizeArrayName, _) = resolvedKind {
                    name = fixedSizeArrayName
                }
                
            case let .failure(error):
                return .failure(error)
            }
        }
        
        return .success(.init(name: name, kind: kind))
    }
    
    private func resolveTypeKind(name: String, value: Any) -> Result<TypeKind, Error> {
        guard let object = value as? [String: Any] else {
            return .failure(.unexpectedType)
        }
        
        if let value = object["Option"] {
            return resolveOptional(value: value)
        } else if let value = object["Map"] {
            return resolveMap(value: value)
        } else if let value = object["Array"] {
            return resolveFixedSizeArray(value: value)
        } else if let value = object["Vec"] {
            return resolveVector(value: value)
        } else if let value = object["TupleStruct"] {
            return resolveTupleStruct(value: value)
        } else if let value = object["Struct"] {
            return resolveStruct(value: value)
        } else if let value = object["Enum"] {
            return resolveEnum(value: value)
        } else if let value = object["Int"] {
            return resolveInt(value: value)
        } else if let value = object["FixedPoint"] {
            return resolveFixedPoint(value: value)
        }
        
        return .failure(.unknownType(value))
    }
}

// MARK: - Type resolvers

extension TypeResolver {
    
    private func resolveOptional(value: Any) -> Result<TypeKind, Error> {
        guard let name = value as? String else {
            return .failure(.other("Invalid optional: is not string"))
        }
        
        return .success(.optional(name))
    }

    private func resolveMap(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid map schema: it is not an object"))
        }
        
        guard let key = value["key"] as? String else {
            return .failure(.other("Invalid map schema: `key` is not string or not found"))
        }
        
        guard let value = value["value"] as? String else {
            return .failure(.other("Invalid map schema: `value` is not string or not found"))
        }
        
        return .success(.map(key, value))
    }

    private func resolveFixedSizeArray(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid array schema: it is not an object"))
        }
        
        guard let length = value["len"] as? UInt else {
            return .failure(.other("Invalid array schema: `len` is not int or not found"))
        }
        
        return .success(.fixedSizeArray("Array\(length)", length))
    }

    private func resolveVector(value: Any) -> Result<TypeKind, Error> {
        guard let vectorType = value as? String else {
            return .failure(.other("Invalid vector contents"))
        }
        
        return .success(.vector(vectorType))
    }

    private func resolveTupleStruct(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid tuple struct schema: it is not an object"))
        }
        
        guard let types = value["types"] as? [String] else {
            return .failure(.other("Invalid tuple struct schema: `types` is not array or not found"))
        }
        
        return .success(.tupleStruct(types))
    }

    private func resolveStruct(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid struct schema: it is not an object"))
        }
        
        guard let declarations = value["declarations"] as? [[String: Any]] else {
            return .failure(.other("Invalid struct schema: `declarations` is not array or not found"))
        }
        
        var structFields: [(String, String)] = []
        for field in declarations {
            guard let name = field["name"] as? String else {
                return .failure(.other("Invalid struct schema: `name` is not string or not found"))
            }
            
            guard let type = field["ty"] as? String else {
                return .failure(.other("Invalid struct schema: `name` is not string or not found"))
            }
            
            structFields.append((name, type))
        }
        
        return .success(.struct(structFields))
    }

    private func resolveEnum(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid enum schema: it is not an object"))
        }
        
        guard let variants = value["variants"] as? [[String: Any]] else {
            return .failure(.other("Invalid enum schema: `variants` is not array or not found"))
        }
        
        var enumCases: [(String, UInt8, [String]?)] = []
        for field in variants {
            guard let name = field["name"] as? String else {
                return .failure(.other("Invalid enum schema: `name` is not string or not found"))
            }
            
            guard let discriminant = field["discriminant"] as? UInt8 else {
                return .failure(.other("Invalid enum schema: `discriminant` is not UInt8 or not found"))
            }
            
            // Currently schema provide only one type, but keep it in array
            let types = (field["ty"] as? String).map { [$0] } ?? nil
            
            enumCases.append((name, discriminant, types))
        }
        
        return .success(.enum(enumCases))
    }
    
    private func resolveInt(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? String else {
            return .failure(.other("Invalid int schema: it is not an appropriate object"))
        }
        
        guard value == "Compact" else {
            return .failure(.other("Invalid int schema: type '\(value)' not supported"))
        }
        
        return .success(.compact)
    }
    
    private func resolveFixedPoint(value: Any) -> Result<TypeKind, Error> {
        guard let value = value as? [String: Any] else {
            return .failure(.other("Invalid fixed point schema: it is not an appropriate object"))
        }
        
        guard let decimalPlaces = value["decimal_places"] as? UInt else {
            return .failure(.other("Invalizd fixed point schema: `decimal_places` is not UInt or not found"))
        }
        
        guard let base = value["base"] as? String else {
            return .failure(.other("Invalid fixed point schema: `base` is not String or not found"))
        }
        
        return .success(.fixedPoint(base, decimalPlaces))
    }
}